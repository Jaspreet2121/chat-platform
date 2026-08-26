defmodule UserService.ProfilePaymentTest do
  @moduledoc """
  The profile payment flow (100 → async QR) on real SQL, with the media writer stubbed at its seam.

  The PATCH request path does NO media work: it stores the identity fields, nulls any stale QR id,
  and flags `upi_qr_pending` — it must never render/upload in-request (a slow or down media service
  can't 503 a profile save). The QR PNG is rendered + stored by the separate, async
  `regenerate_upi_qr/1` (which the gateway retries + broadcasts around). The LOCKED canonical payload
  is unchanged — the renderer still produces the byte-identical PNG.
  """
  use UserService.DataCase, async: false

  alias UserService.Profiles

  @tenant_zero "00000000-0000-0000-0000-000000000001"

  defmodule WriterStub do
    @moduledoc false
    def store_png(user_id, app_id, png) do
      id = Ecto.UUID.generate()

      send(
        :profile_payment_test,
        {:stored, %{user_id: user_id, app_id: app_id, png: png, id: id}}
      )

      {:ok, id}
    end
  end

  defmodule ErroringWriter do
    @moduledoc false
    # Announces every call so a test can prove the PATCH path NEVER invokes it, and fails so the
    # async regenerate returns an error (feeding the gateway's retry).
    def store_png(_user_id, _app_id, _png) do
      send(:profile_payment_test, {:writer_called})
      {:error, :media_down}
    end
  end

  defmodule MediaStub do
    @moduledoc false
    def purge_asset(attrs) do
      send(:profile_payment_test, {:purged, attrs["media_id"]})
      {:ok, %{purged: true}}
    end
  end

  setup do
    prev = Application.get_env(:user_service, :user_profile_persistence, false)
    prev_writer = Application.get_env(:user_service, :upi_media_writer)
    prev_media = Application.get_env(:shared_infra, :media_client_adapter)

    Application.put_env(:user_service, :user_profile_persistence, true)
    Application.put_env(:user_service, :upi_media_writer, WriterStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Process.register(self(), :profile_payment_test)

    on_exit(fn ->
      Application.put_env(:user_service, :user_profile_persistence, prev)

      restore = fn app, key, value ->
        if value, do: Application.put_env(app, key, value), else: Application.delete_env(app, key)
      end

      restore.(:user_service, :upi_media_writer, prev_writer)
      restore.(:shared_infra, :media_client_adapter, prev_media)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @tenant_zero, "+1#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp patch!(user_id, attrs) do
    {:ok, response} =
      attrs
      |> Map.merge(%{"user_id" => user_id, "app_id" => @tenant_zero})
      |> Map.put_new("display_name", "Shop Owner")
      |> Profiles.update_current_profile()

    response
  end

  defp regenerate!(user_id) do
    Profiles.regenerate_upi_qr(%{"user_id" => user_id, "app_id" => @tenant_zero})
  end

  @scanned "upi://pay?pa=shop@okaxis&pn=Sharma%20Stores&mc=5411&tr=INV42"

  @tag :postgres_integration
  test "PATCH stores identity + passthrough and flags pending — but does NO media work in-request" do
    user = user!()
    response = patch!(user, %{"upi_qr_payload" => @scanned})

    assert response.upi_id == "shop@okaxis"
    assert response.payment_name == "Sharma Stores"
    assert response.upi_merchant == %{"mc" => "5411", "tr" => "INV42"}

    # No synchronous generation: the QR id is not set yet, the caller is told regeneration is pending.
    assert is_nil(response.upi_qr_media_id)
    assert response.upi_qr_pending == true
    refute_receive {:stored, _}, 50
  end

  @tag :postgres_integration
  test "PATCH latency is independent of the store: a writer that would error/announce is never called" do
    # Even a writer that fails loudly on every call must never run in the PATCH path.
    Application.put_env(:user_service, :upi_media_writer, ErroringWriter)

    user = user!()
    response = patch!(user, %{"upi_qr_payload" => @scanned})

    # Fields stored, request succeeds, pending flagged — and the media writer was NOT invoked.
    assert response.upi_id == "shop@okaxis"
    assert response.upi_qr_pending == true
    assert is_nil(response.upi_qr_media_id)
    refute_receive {:writer_called}, 100

    # The failure only surfaces in the async regenerate — never as a PATCH error.
    assert {:error, :upi_qr_failed} = regenerate!(user)
    assert_receive {:writer_called}
  end

  @tag :postgres_integration
  test "async regenerate renders the LOCKED canonical payload, stores it, and persists the id" do
    user = user!()
    patch!(user, %{"upi_qr_payload" => @scanned})

    assert {:ok, %{upi_qr_media_id: media_id}} = regenerate!(user)
    assert is_binary(media_id)

    assert_receive {:stored, stored}
    assert stored.user_id == user
    assert stored.app_id == @tenant_zero
    assert stored.id == media_id

    {:ok, expected_png} =
      UserService.UpiQr.render_png(
        "upi://pay?pa=shop%40okaxis&pn=Sharma%20Stores&cu=INR&mc=5411&tr=INV42"
      )

    assert stored.png == expected_png

    # The freshly-generated id is now readable on the profile (what the broadcast tells clients to refetch).
    {:ok, current} = Profiles.get_current_profile(%{"user_id" => user})
    assert current.upi_qr_media_id == media_id
  end

  @tag :postgres_integration
  test "changing the identity purges the replaced asset in-request and regenerates a NEW one" do
    user = user!()
    patch!(user, %{"upi_qr_payload" => @scanned})
    assert {:ok, %{upi_qr_media_id: first_id}} = regenerate!(user)
    assert_receive {:stored, %{id: ^first_id}}

    # The change nulls the stale id (no wrong QR served in the gap), purges the old asset off-path,
    # and re-flags pending — still no synchronous generation.
    changed = patch!(user, %{"upi_qr_payload" => "upi://pay?pa=new@icici&pn=New"})
    assert changed.upi_id == "new@icici"
    assert is_nil(changed.upi_qr_media_id)
    assert changed.upi_qr_pending == true
    assert_receive {:purged, ^first_id}
    refute_receive {:stored, _}, 50

    assert {:ok, %{upi_qr_media_id: second_id}} = regenerate!(user)
    assert_receive {:stored, %{id: ^second_id}}
    refute second_id == first_id
  end

  @tag :postgres_integration
  test "clearing nulls the whole payment block, purges the asset, and does NOT regenerate" do
    user = user!()
    patch!(user, %{"upi_qr_payload" => @scanned})
    assert {:ok, %{upi_qr_media_id: qr_id}} = regenerate!(user)
    assert_receive {:stored, %{id: ^qr_id}}

    cleared = patch!(user, %{"upi_qr_payload" => nil})
    assert is_nil(cleared.upi_id)
    assert is_nil(cleared.payment_name)
    assert is_nil(cleared.upi_merchant)
    assert is_nil(cleared.upi_qr_media_id)
    # Clearing needs no regeneration.
    assert cleared.upi_qr_pending == false
    assert_receive {:purged, ^qr_id}
    refute_receive {:stored, _}, 50

    # Even if a regenerate fires (race), a cleared identity yields nothing to generate.
    assert {:ok, %{upi_qr_media_id: nil}} = regenerate!(user)
    refute_receive {:stored, _}, 50
  end

  @tag :postgres_integration
  test "manual VPA entry flags pending + regenerates (no merchant params); junk inputs are typed errors" do
    user = user!()
    response = patch!(user, %{"upi_id" => "manual@paytm", "payment_name" => "Manual Name"})

    assert response.upi_id == "manual@paytm"
    assert response.upi_merchant == %{}
    assert response.upi_qr_pending == true

    assert {:ok, %{upi_qr_media_id: id}} = regenerate!(user)
    assert is_binary(id)
    assert_receive {:stored, _}

    base = %{"user_id" => user, "app_id" => @tenant_zero, "display_name" => "X"}

    assert {:error, :invalid_scheme} =
             Profiles.update_current_profile(Map.put(base, "upi_qr_payload", "http://x?pa=a@b"))

    assert {:error, :missing_pa} =
             Profiles.update_current_profile(Map.put(base, "upi_qr_payload", "upi://pay?pn=x"))

    assert {:error, :invalid_vpa} =
             Profiles.update_current_profile(Map.put(base, "upi_id", "not a vpa"))
  end

  @tag :postgres_integration
  test "a non-payment PATCH neither flags pending nor touches media" do
    user = user!()
    response = patch!(user, %{"bio" => "hello"})

    assert response.bio == "hello"
    assert response.upi_qr_pending == false
    refute_receive {:stored, _}, 50
    refute_receive {:purged, _}, 50
  end

  @tag :postgres_integration
  test "visibility: validated values only, PARTIAL merge, defaults applied in every response" do
    user = user!()

    # Defaults before anything is set.
    first = patch!(user, %{"bio" => "hello"})
    assert first.profile_visibility == %{"payment" => "contacts", "business" => "everyone"}

    updated = patch!(user, %{"profile_visibility" => %{"payment" => "everyone"}})
    assert updated.profile_visibility == %{"payment" => "everyone", "business" => "everyone"}

    # The earlier key survives a partial update of the other.
    merged = patch!(user, %{"profile_visibility" => %{"business" => "nobody"}})
    assert merged.profile_visibility == %{"payment" => "everyone", "business" => "nobody"}

    assert {:error, :invalid_visibility} =
             Profiles.update_current_profile(%{
               "user_id" => user,
               "display_name" => "X",
               "profile_visibility" => %{"payment" => "friends_of_friends"}
             })
  end

  @tag :postgres_integration
  test "the public card carries the payment/business fields + visibility; NEVER the merchant map" do
    user = user!()

    patch!(user, %{
      "upi_qr_payload" => @scanned,
      "address" => "12 Market Rd",
      "website" => "https://sharma.example"
    })

    assert {:ok, card} =
             Profiles.get_public_profile(%{"user_id" => user, "app_id" => @tenant_zero})

    assert card.upi_id == "shop@okaxis"
    assert card.address == "12 Market Rd"
    assert card.profile_visibility == %{"payment" => "contacts", "business" => "everyone"}
    refute Map.has_key?(card, :upi_merchant)
  end
end

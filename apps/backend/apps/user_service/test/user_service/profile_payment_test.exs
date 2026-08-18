defmodule UserService.ProfilePaymentTest do
  @moduledoc """
  The profile payment flow (100) on real SQL, with the media writer stubbed at its seam: a scanned
  payload sets upi_id/payment_name + the merchant passthrough and generates the QR from the LOCKED
  canonical payload; changing the identity regenerates (new asset, old purged); clearing nulls the
  block and purges; manual VPA entry works; junk payloads are typed errors; visibility updates are
  validated, merged, and defaulted.
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

  @scanned "upi://pay?pa=shop@okaxis&pn=Sharma%20Stores&mc=5411&tr=INV42"

  @tag :postgres_integration
  test "scan → identity + passthrough stored; the QR renders from the LOCKED canonical payload" do
    user = user!()
    response = patch!(user, %{"upi_qr_payload" => @scanned})

    assert response.upi_id == "shop@okaxis"
    assert response.payment_name == "Sharma Stores"
    assert response.upi_merchant == %{"mc" => "5411", "tr" => "INV42"}
    assert is_binary(response.upi_qr_media_id)

    assert_receive {:stored, stored}
    assert stored.user_id == user
    assert stored.app_id == @tenant_zero

    # The writer received the PNG of the canonical payload — locked via the deterministic renderer.
    {:ok, expected_png} =
      UserService.UpiQr.render_png(
        "upi://pay?pa=shop%40okaxis&pn=Sharma%20Stores&cu=INR&mc=5411&tr=INV42"
      )

    assert stored.png == expected_png
  end

  @tag :postgres_integration
  test "changing the identity REGENERATES (new asset id) and purges the replaced one" do
    user = user!()
    first = patch!(user, %{"upi_qr_payload" => @scanned})
    assert_receive {:stored, %{id: first_id}}
    assert first.upi_qr_media_id == first_id

    second = patch!(user, %{"upi_qr_payload" => "upi://pay?pa=new@icici&pn=New"})
    assert_receive {:stored, %{id: second_id}}
    assert second.upi_qr_media_id == second_id
    refute second_id == first_id
    assert_receive {:purged, ^first_id}
  end

  @tag :postgres_integration
  test "clearing nulls the whole payment block and purges the asset" do
    user = user!()
    patch!(user, %{"upi_qr_payload" => @scanned})
    assert_receive {:stored, %{id: qr_id}}

    cleared = patch!(user, %{"upi_qr_payload" => nil})
    assert is_nil(cleared.upi_id)
    assert is_nil(cleared.payment_name)
    assert is_nil(cleared.upi_merchant)
    assert is_nil(cleared.upi_qr_media_id)
    assert_receive {:purged, ^qr_id}
    refute_receive {:stored, _}, 50
  end

  @tag :postgres_integration
  test "manual VPA entry generates too (no merchant params); junk inputs are typed errors" do
    user = user!()
    response = patch!(user, %{"upi_id" => "manual@paytm", "payment_name" => "Manual Name"})

    assert response.upi_id == "manual@paytm"
    assert response.upi_merchant == %{}
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

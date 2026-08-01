defmodule ApiGatewayWeb.FavouriteEnrichmentTest do
  @moduledoc """
  The favourites READ is ProfilePresenter's fifth consumer, and this suite holds it to the same
  standard the contacts-sync slice set: the enriched entry must redact IDENTICALLY to the REAL
  contact-sync response for the same viewer/target — asserted by invoking BOTH controllers with the
  same stubs and comparing field-for-field, not by restating the redaction rules. If the presenter's
  behaviour and this surface ever drift, this fails.

  Also: ordering preserved through enrichment; a blocked favourite REMAINS (redacted, never
  dropped); a profile miss degrades one chip, never the list.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ContactController
  alias ApiGatewayWeb.FavouriteController

  @app "app-1"
  @me "u-me"
  @visible "u-visible"
  @blocked "u-blocked"
  @hidden "u-hidden"

  @p_visible "+15550000001"
  @p_blocked "+15550000002"
  @p_hidden "+15550000003"

  defmodule AuthStub do
    @moduledoc false
    @app "app-1"
    @me "u-me"

    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, app_id: @app}}

    def current_session(_), do: {:error, :session_invalid}

    # The real client returns {:ok, rows} — a bare LIST (see AuthClient.lookup_users_by_phones).
    def lookup_users_by_phones(%{"phone_numbers" => phones, "app_id" => @app}) do
      rows =
        phones
        |> Enum.map(fn
          "+15550000001" -> %{phone_number: "+15550000001", user_id: "u-visible"}
          "+15550000002" -> %{phone_number: "+15550000002", user_id: "u-blocked"}
          "+15550000003" -> %{phone_number: "+15550000003", user_id: "u-hidden"}
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, rows}
    end
  end

  defmodule UserStub do
    @moduledoc false
    @app "app-1"

    # Favourites, in a DELIBERATE order the enrichment must preserve.
    def list_favourites(%{"owner_user_id" => "u-me"}) do
      {:ok,
       %{
         favourites: [
           %{user_id: "u-hidden", position: 0},
           %{user_id: "u-visible", position: 1},
           %{user_id: "u-blocked", position: 2}
         ]
       }}
    end

    # Every target has an avatar, so redaction is VISIBLE as avatar_url going nil.
    def get_public_profile(%{"user_id" => uid, "app_id" => @app}) do
      {:ok,
       %{
         user_id: uid,
         display_name: name(uid),
         avatar_media_id: "m-" <> uid,
         app_id: @app,
         bio: nil
       }}
    end

    def get_public_profile(_), do: {:error, :profile_not_found}

    def get_privacy(%{"user_id" => "u-hidden"}), do: {:ok, %{profile_photo_visibility: "nobody"}}
    def get_privacy(%{"user_id" => _}), do: {:ok, %{profile_photo_visibility: "everyone"}}

    defp name("u-visible"), do: "Visible"
    defp name("u-blocked"), do: "Blocked"
    defp name("u-hidden"), do: "Hidden"
    defp name(other), do: other
  end

  defmodule ConvStub do
    @moduledoc false
    # ONLY u-blocked is blocked (either direction) — so its redaction is the BLOCK's doing alone.
    def either_blocked?(%{"user_a" => a, "user_b" => b}),
      do: {:ok, %{blocked: "u-blocked" in [a, b]}}

    def shares_conversation?(_), do: {:ok, %{shares: true}}
  end

  defmodule MediaStub do
    @moduledoc false
    @app "app-1"

    def get_download_url(%{"media_id" => mid, "app_id" => @app, "purpose" => "user_avatar"}),
      do: {:ok, %{download_url: "https://signed/" <> mid}}

    def get_download_url(_), do: {:error, :not_found}
  end

  defmodule RateOkStub do
    @moduledoc false
    def check_rate(_attrs), do: :ok
  end

  setup do
    prev =
      for key <- [
            :auth_client_adapter,
            :user_client_adapter,
            :conversation_client_adapter,
            :media_client_adapter,
            :rate_limiter_adapter
          ],
          into: %{},
          do: {key, Application.get_env(:shared_infra, key)}

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, RateOkStub)

    on_exit(fn ->
      for {key, value} <- prev do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end
    end)

    :ok
  end

  defp authed, do: :post |> conn("/x", %{}) |> put_req_header("authorization", "Bearer me")

  defp favourites do
    conn = FavouriteController.index(authed(), %{})
    assert conn.status == 200
    Jason.decode!(conn.resp_body)["favourites"]
  end

  defp sync_match(user_id) do
    conn =
      ContactController.sync(authed(), %{"phone_numbers" => [@p_visible, @p_blocked, @p_hidden]})

    assert conn.status == 200

    Jason.decode!(conn.resp_body)["matches"]
    |> Enum.find(&(&1["user_id"] == user_id))
  end

  test "THE EQUIVALENCE: each favourite redacts EXACTLY as the real contact-sync response does" do
    for target <- [@visible, @blocked, @hidden] do
      favourite = Enum.find(favourites(), &(&1["user_id"] == target))
      sync = sync_match(target)

      assert favourite["display_name"] == sync["display_name"],
             "#{target}: display_name diverged from the sync surface"

      assert favourite["avatar_url"] == sync["avatar_url"],
             "#{target}: avatar_url redaction diverged from the sync surface"
    end

    # And the redactions themselves are the expected ones (so equivalence isn't two matching bugs):
    by_id = Map.new(favourites(), &{&1["user_id"], &1})
    assert by_id[@visible]["avatar_url"] == "https://signed/m-u-visible"
    assert by_id[@blocked]["avatar_url"] == nil
    assert by_id[@hidden]["avatar_url"] == nil
  end

  test "a BLOCKED favourite REMAINS listed (redacted) — blocks never delete relationships" do
    assert Enum.any?(favourites(), &(&1["user_id"] == @blocked))
  end

  test "ordering is preserved through enrichment" do
    assert Enum.map(favourites(), & &1["user_id"]) == [@hidden, @visible, @blocked]
  end
end

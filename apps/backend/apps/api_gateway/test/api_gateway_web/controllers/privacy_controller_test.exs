defmodule ApiGatewayWeb.PrivacyControllerTest do
  @moduledoc """
  GET/PATCH /api/v1/privacy — the first-party privacy surface. Session-authed; the settings are the session
  user's own. Stubs AuthClient + UserClient (the store CRUD itself is proven in UserService.PrivacyTest).
  Proves the contract: GET returns all three, PATCH is SPARSE, empty body → 400, invalid enum → 400, and the
  session gate.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.PrivacyController

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer me"}), do: {:ok, %{user_id: "u1", app_id: "app1"}}
    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    @keys ["last_seen_visibility", "profile_photo_visibility", "read_receipts_enabled"]

    def get_privacy(%{"user_id" => "u1"}),
      do:
        {:ok,
         %{last_seen_visibility: "contacts", profile_photo_visibility: "everyone", read_receipts_enabled: true}}

    def update_privacy(attrs) do
      changes = Map.take(attrs, @keys)

      cond do
        changes == %{} -> {:error, :privacy_empty}
        Map.get(changes, "last_seen_visibility") == "mars" -> {:error, :privacy_invalid_value}
        Map.get(changes, "read_receipts_enabled") == "maybe" -> {:error, :privacy_invalid_value}
        true -> {:ok, merge_defaults(changes)}
      end
    end

    defp merge_defaults(changes) do
      %{last_seen_visibility: "contacts", profile_photo_visibility: "contacts", read_receipts_enabled: true}
      |> Map.merge(Map.new(changes, fn {k, v} -> {String.to_atom(k), v} end))
    end
  end

  setup do
    prev_auth = Application.get_env(:shared_infra, :auth_client_adapter)
    prev_user = Application.get_env(:shared_infra, :user_client_adapter)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev_auth)
      restore(:user_client_adapter, prev_user)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed(token \\ "me") do
    :patch |> conn("/api/v1/privacy", %{}) |> put_req_header("authorization", "Bearer #{token}")
  end

  test "GET returns all three settings" do
    conn = PrivacyController.show(authed(), %{})
    assert conn.status == 200

    assert Jason.decode!(conn.resp_body) == %{
             "last_seen_visibility" => "contacts",
             "profile_photo_visibility" => "everyone",
             "read_receipts_enabled" => true
           }
  end

  test "PATCH a SPARSE body (one key) → 200 with the full updated settings" do
    conn = PrivacyController.update(authed(), %{"read_receipts_enabled" => false})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert body["read_receipts_enabled"] == false
    # The untouched keys keep their (default) values.
    assert body["last_seen_visibility"] == "contacts"
    assert body["profile_photo_visibility"] == "contacts"
  end

  test "PATCH with an EMPTY body → 400 privacy.empty" do
    conn = PrivacyController.update(authed(), %{})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "privacy.empty"
  end

  test "PATCH with an unknown key only → 400 privacy.empty (unknown keys are ignored)" do
    conn = PrivacyController.update(authed(), %{"nope" => "x"})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "privacy.empty"
  end

  test "PATCH an invalid enum → 400 privacy.invalid_value" do
    conn = PrivacyController.update(authed(), %{"last_seen_visibility" => "mars"})
    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "privacy.invalid_value"
  end

  test "no session → 401" do
    conn = PrivacyController.show(authed("nobody"), %{})
    assert conn.status == 401
  end
end

defmodule ApiGatewayWeb.MediaControllerAuthzTest do
  @moduledoc """
  create_upload's authorization gate (gateway-side, like the gallery — media_service can't reach
  conversation_service in prod). A `message` upload requires active participation; a `group_avatar` upload
  requires owner/admin. Enforcement runs only when a conversation_id is supplied (Phase 5 frontend will
  always send it). No DB: the media client is stubbed, so these prove the gate + the field-passing without
  Postgres. Row persistence + ownership are covered by media_persistence_postgres_integration_test.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.MediaController

  @app "44444444-4444-4444-8444-444444444444"
  @member "22222222-2222-4222-8222-222222222222"
  @admin "55555555-5555-4555-8555-555555555555"
  @stranger "33333333-3333-4333-8333-333333333333"
  @convo "11111111-1111-4111-8111-111111111111"

  defmodule AuthStub do
    @moduledoc false
    @app "44444444-4444-4444-8444-444444444444"
    # The bearer token IS the caller's user_id (test convenience); app_id is fixed to @app.
    def current_session(%{"authorization" => "Bearer " <> user_id}) when user_id != "",
      do: {:ok, %{user_id: user_id, app_id: @app}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    @member "22222222-2222-4222-8222-222222222222"
    @admin "55555555-5555-4555-8555-555555555555"

    # @member is a plain member; @admin is the owner. A stranger isn't a participant → forbidden.
    def get_conversation(%{"user_id" => @member}), do: {:ok, %{participants: participants()}}
    def get_conversation(%{"user_id" => @admin}), do: {:ok, %{participants: participants()}}
    def get_conversation(_), do: {:error, :conversation_forbidden}

    defp participants do
      [%{user_id: @member, role: "member"}, %{user_id: @admin, role: "owner"}]
    end
  end

  defmodule MediaStub do
    @moduledoc false
    # Echo the received attrs back so the test can assert what the controller passed. Never touches a DB.
    def create_upload(attrs) do
      {:ok,
       %{
         media_id: "m1",
         upload_url: "https://minio.local/put",
         expires_at: "2026-07-09T00:00:00Z",
         object_key: "media/#{attrs["owner_user_id"]}/m1/f.png",
         echo_owner: attrs["owner_user_id"],
         echo_app_id: attrs["app_id"],
         echo_purpose: attrs["purpose"],
         echo_conversation_id: attrs["conversation_id"]
       }}
    end

    def complete_upload(attrs) do
      {:ok, %{media_id: attrs["media_id"], status: "ready", echo_keys: Map.keys(attrs)}}
    end
  end

  setup do
    prev = %{
      persist: Application.get_env(:media_service, :media_persistence, false),
      media: Application.get_env(:shared_infra, :media_client_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter)
    }

    Application.put_env(:media_service, :media_persistence, true)
    Application.put_env(:shared_infra, :media_client_adapter, MediaStub)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      Application.put_env(:media_service, :media_persistence, prev.persist)
      restore(:media_client_adapter, prev.media)
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp upload_conn(user_id) do
    :post
    |> conn("/api/v1/media/uploads", %{})
    |> put_req_header("authorization", "Bearer " <> user_id)
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp create_params(extra) do
    Map.merge(%{"filename" => "f.png", "content_type" => "image/png", "size_bytes" => 123}, extra)
  end

  describe "create_upload authorization" do
    test "message by an active participant → 201, passes owner/app_id/purpose/conversation_id" do
      params = create_params(%{"purpose" => "message", "conversation_id" => @convo})
      conn = MediaController.create_upload(upload_conn(@member), params)

      assert conn.status == 201
      b = body(conn)
      assert b["echo_owner"] == @member
      assert b["echo_app_id"] == @app
      assert b["echo_purpose"] == "message"
      assert b["echo_conversation_id"] == @convo
    end

    test "message by a NON-participant → 404 (no row: the gate short-circuits before the media client)" do
      params = create_params(%{"purpose" => "message", "conversation_id" => @convo})
      conn = MediaController.create_upload(upload_conn(@stranger), params)

      assert conn.status == 404
      assert body(conn)["error"]["code"] == "media.not_found"
    end

    test "group_avatar by a member who is NOT owner/admin → 403 (matches group-profile), no media call" do
      params = create_params(%{"purpose" => "group_avatar", "conversation_id" => @convo})
      conn = MediaController.create_upload(upload_conn(@member), params)

      assert conn.status == 403
      assert body(conn)["error"]["code"] == "media.forbidden"
    end

    test "group_avatar by the owner → 201" do
      params = create_params(%{"purpose" => "group_avatar", "conversation_id" => @convo})
      conn = MediaController.create_upload(upload_conn(@admin), params)

      assert conn.status == 201
      assert body(conn)["echo_purpose"] == "group_avatar"
    end

    test "message with NO conversation_id (today's frontend) → 201, no membership check (Phase-5 gap)" do
      params = create_params(%{"purpose" => "message"})
      conn = MediaController.create_upload(upload_conn(@member), params)

      assert conn.status == 201
      assert body(conn)["echo_conversation_id"] == nil
    end

    # THE PURPOSE PASSTHROUGH (110). upload_purpose/1 coerces anything unrecognised to "message"
    # instead of 400-ing, so a purpose missing from its whitelist is not rejected — it is silently
    # REWRITTEN, then judged by the wrong purpose's rules downstream. That is exactly how every E2EE
    # attachment broke in production: "sealed_media" became "message", and MediaService.Media's
    # content-type allow-list for "message" refuses the application/octet-stream that sealed media
    # REQUIRES → 400 media.invalid_request. These two tests pin both halves of that behaviour.
    test "sealed_media reaches the media client as sealed_media (NOT coerced to message)" do
      params =
        create_params(%{
          "purpose" => "sealed_media",
          # Ciphertext: opaque bytes, and the only content type the media service accepts here.
          "content_type" => "application/octet-stream",
          "conversation_id" => @convo
        })

      conn = MediaController.create_upload(upload_conn(@member), params)

      assert conn.status == 201
      # Drop "sealed_media" from upload_purpose/1's whitelist and this reads "message" — the
      # production failure, caught here instead of on a user's phone.
      assert body(conn)["echo_purpose"] == "sealed_media"
      # It is membership-scoped like a normal attachment (authorize_upload's sealed_media clause).
      assert body(conn)["echo_conversation_id"] == @convo
    end

    test "sealed_media by a NON-participant → 404, same membership scope as a message attachment" do
      params =
        create_params(%{
          "purpose" => "sealed_media",
          "content_type" => "application/octet-stream",
          "conversation_id" => @convo
        })

      conn = MediaController.create_upload(upload_conn(@stranger), params)

      assert conn.status == 404
      assert body(conn)["error"]["code"] == "media.not_found"
    end

    test "an UNKNOWN purpose still coerces to message (the deliberate fallback, unchanged)" do
      for unknown <- ["nonsense", "", nil] do
        params = create_params(%{"purpose" => unknown})
        conn = MediaController.create_upload(upload_conn(@member), params)

        assert conn.status == 201
        assert body(conn)["echo_purpose"] == "message"
      end
    end

    test "create response STILL returns object_key (TODO(phase-5) — the live frontend depends on it)" do
      params = create_params(%{"purpose" => "message", "conversation_id" => @convo})
      conn = MediaController.create_upload(upload_conn(@member), params)

      # Pins decision (c): removing object_key here would break message metadata + avatar flows until Phase 5.
      assert body(conn)["object_key"] == "media/#{@member}/m1/f.png"
    end
  end

  describe "complete_upload" do
    test "passes media_id + owner + app_id and NEVER a client object_key" do
      # The client may send object_key in the body; the controller must drop it.
      params = %{"object_key" => "media/victim/secret/steal.png"}

      conn =
        MediaController.complete_upload(upload_conn(@member), Map.put(params, "media_id", "m1"))

      assert conn.status == 200
      keys = body(conn)["echo_keys"]
      assert "media_id" in keys
      assert "owner_user_id" in keys
      assert "app_id" in keys
      refute "object_key" in keys
    end
  end
end

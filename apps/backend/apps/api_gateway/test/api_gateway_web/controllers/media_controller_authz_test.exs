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
    #
    # ENFORCES the media service's real create-side contract for the anchored purposes, the same way the
    # UPI double enforces complete_upload's required attrs — an echo-only double would have happily
    # "succeeded" on the very anchorless sealed upload that broke production.
    @anchored ["sealed_media"]

    def create_upload(attrs) do
      with :ok <- require_anchor(attrs), do: do_create_upload(attrs)
    end

    def anchor_asset(%{"conversation_id" => conversation_id, "media_id" => media_id} = attrs) do
      # Mirrors MediaService.Media.anchor_asset/1: owner-only, unanchored-only, idempotent.
      case media_id do
        "unanchored" ->
          {:ok,
           %{
             media_id: media_id,
             conversation_id: conversation_id,
             anchored: true,
             echo_owner: attrs["owner_user_id"],
             echo_app_id: attrs["app_id"]
           }}

        "already-same" ->
          {:ok, %{media_id: media_id, conversation_id: conversation_id, anchored: false}}

        "already-other" ->
          {:error, :media_already_anchored}

        _ ->
          {:error, :not_found}
      end
    end

    defp require_anchor(attrs) do
      anchor = attrs["conversation_id"]

      if attrs["purpose"] in @anchored and not (is_binary(anchor) and anchor != "") do
        {:error, :media_conversation_required}
      else
        :ok
      end
    end

    defp do_create_upload(attrs) do
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

    # Multipart (112) — echoes the same fields so the tests can assert that these actions go through
    # the SAME purpose/authorization path as the single-PUT create.
    def create_multipart_upload(attrs) do
      with :ok <- require_anchor(attrs), do: do_create_multipart_upload(attrs)
    end

    defp do_create_multipart_upload(attrs) do
      {:ok,
       %{
         media_id: "m1",
         upload_id: "upload-1",
         object_key: "media/#{attrs["owner_user_id"]}/m1/f.bin",
         part_size: 5_242_880,
         echo_owner: attrs["owner_user_id"],
         echo_app_id: attrs["app_id"],
         echo_purpose: attrs["purpose"],
         echo_conversation_id: attrs["conversation_id"]
       }}
    end

    def presign_upload_parts(attrs) do
      {:ok,
       %{
         parts:
           Enum.map(attrs["part_numbers"] || [], &%{part_number: &1, url: "https://s/#{&1}"}),
         echo_owner: attrs["owner_user_id"],
         echo_app_id: attrs["app_id"],
         echo_upload_id: attrs["upload_id"]
       }}
    end

    def complete_multipart_upload(attrs) do
      {:ok, %{media_id: attrs["media_id"], status: "ready", echo_upload_id: attrs["upload_id"]}}
    end

    def abort_multipart_upload(attrs) do
      {:ok, %{aborted: true, media_id: attrs["media_id"], echo_upload_id: attrs["upload_id"]}}
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

  describe "multipart upload authorization (112)" do
    test "create_multipart runs the SAME purpose whitelist — sealed_media is NOT coerced" do
      params =
        create_params(%{
          "purpose" => "sealed_media",
          "content_type" => "application/octet-stream",
          "conversation_id" => @convo
        })

      conn = MediaController.create_multipart(upload_conn(@member), params)

      assert conn.status == 201
      b = body(conn)

      # Drop "sealed_media" from upload_purpose/1's whitelist and this reads "message" — the same
      # mutation that d4af319 pinned for the single-PUT path, now pinned for multipart too.
      assert b["echo_purpose"] == "sealed_media"
      assert b["echo_owner"] == @member
      assert b["echo_app_id"] == @app
      assert b["part_size"] == 5_242_880
      assert b["upload_id"] == "upload-1"
    end

    test "create_multipart by a NON-PARTICIPANT is 404 — same gate as the single PUT" do
      params = create_params(%{"purpose" => "message", "conversation_id" => @convo})
      conn = MediaController.create_multipart(upload_conn(@stranger), params)

      assert conn.status == 404
      assert body(conn)["error"]["code"] == "media.not_found"
    end

    test "create_multipart for a group_avatar by a non-admin is 403, like the single PUT" do
      params = create_params(%{"purpose" => "group_avatar", "conversation_id" => @convo})
      conn = MediaController.create_multipart(upload_conn(@member), params)

      assert conn.status == 403
    end

    test "an UNKNOWN purpose still coerces to message (the deliberate fallback, unchanged)" do
      params = create_params(%{"purpose" => "nonsense"})
      conn = MediaController.create_multipart(upload_conn(@member), params)

      assert conn.status == 201
      assert body(conn)["echo_purpose"] == "message"
    end

    test "parts / complete / abort inject the session identity and the path upload_id" do
      parts =
        MediaController.multipart_parts(upload_conn(@member), %{
          "upload_id" => "upload-9",
          "media_id" => "m1",
          "part_numbers" => [1, 2]
        })

      assert parts.status == 200
      pb = body(parts)
      assert pb["echo_upload_id"] == "upload-9"

      # Identity comes from the SESSION, never from the body — a client cannot upload as someone else.
      assert pb["echo_owner"] == @member
      assert pb["echo_app_id"] == @app
      assert Enum.map(pb["parts"], & &1["part_number"]) == [1, 2]

      complete =
        MediaController.multipart_complete(upload_conn(@member), %{
          "upload_id" => "upload-9",
          "media_id" => "m1",
          "parts" => [%{"part_number" => 1, "etag" => "\"e\""}]
        })

      assert complete.status == 200

      # THE CONVERGENCE REQUIREMENT: same shape as complete_upload, so clients keep one post-upload path.
      assert body(complete)["status"] == "ready"

      abort =
        MediaController.multipart_abort(upload_conn(@member), %{
          "upload_id" => "upload-9",
          "media_id" => "m1"
        })

      assert abort.status == 200
      assert body(abort)["aborted"] == true
    end

    test "no session → 401 on every multipart action" do
      unauthed = fn -> :post |> conn("/api/v1/media/upload/multipart", %{}) end

      assert MediaController.create_multipart(unauthed.(), create_params(%{})).status == 401

      assert MediaController.multipart_parts(unauthed.(), %{
               "upload_id" => "u",
               "media_id" => "m",
               "part_numbers" => [1]
             }).status == 401

      assert MediaController.multipart_abort(unauthed.(), %{"upload_id" => "u", "media_id" => "m"}).status ==
               401
    end
  end

  describe "sealed_media requires a conversation anchor at create (113)" do
    test "single create with NO conversation_id → 422 media.conversation_required" do
      params =
        create_params(%{
          "purpose" => "sealed_media",
          "content_type" => "application/octet-stream"
        })

      conn = MediaController.create_upload(upload_conn(@member), params)

      assert conn.status == 422
      assert body(conn)["error"]["code"] == "media.conversation_required"
    end

    test "single create with a BLANK conversation_id → 422 (not treated as supplied)" do
      params =
        create_params(%{
          "purpose" => "sealed_media",
          "content_type" => "application/octet-stream",
          "conversation_id" => ""
        })

      conn = MediaController.create_upload(upload_conn(@member), params)

      assert conn.status == 422
      assert body(conn)["error"]["code"] == "media.conversation_required"
    end

    test "MULTIPART create with NO conversation_id → 422 (the second create path)" do
      params =
        create_params(%{
          "purpose" => "sealed_media",
          "content_type" => "application/octet-stream"
        })

      conn = MediaController.create_multipart(upload_conn(@member), params)

      assert conn.status == 422
      assert body(conn)["error"]["code"] == "media.conversation_required"
    end

    test "anchored sealed create by a participant → 201 and the anchor is persisted" do
      params =
        create_params(%{
          "purpose" => "sealed_media",
          "content_type" => "application/octet-stream",
          "conversation_id" => @convo
        })

      conn = MediaController.create_upload(upload_conn(@member), params)

      assert conn.status == 201
      assert body(conn)["echo_conversation_id"] == @convo
      assert body(conn)["echo_purpose"] == "sealed_media"
    end

    test "sealed create naming a conversation the uploader is NOT in → 404" do
      params =
        create_params(%{
          "purpose" => "sealed_media",
          "content_type" => "application/octet-stream",
          "conversation_id" => @convo
        })

      assert MediaController.create_upload(upload_conn(@stranger), params).status == 404
      assert MediaController.create_multipart(upload_conn(@stranger), params).status == 404
    end

    test "plaintext message with no conversation_id still succeeds (clients have not shipped it yet)" do
      params = create_params(%{"purpose" => "message"})

      assert MediaController.create_upload(upload_conn(@member), params).status == 201
    end

    test "user_avatar needs no anchor" do
      assert MediaController.create_upload(
               upload_conn(@member),
               create_params(%{"purpose" => "user_avatar"})
             ).status ==
               201
    end
  end

  describe "anchor (client-assisted recovery for legacy unanchored assets)" do
    test "owner who is a participant anchors an unanchored asset → 200" do
      conn =
        MediaController.anchor(upload_conn(@member), %{
          "media_id" => "unanchored",
          "conversation_id" => @convo
        })

      assert conn.status == 200
      b = body(conn)
      assert b["anchored"] == true
      assert b["conversation_id"] == @convo
      assert b["echo_owner"] == @member
      assert b["echo_app_id"] == @app
    end

    test "re-anchoring to the SAME conversation is idempotent → 200" do
      conn =
        MediaController.anchor(upload_conn(@member), %{
          "media_id" => "already-same",
          "conversation_id" => @convo
        })

      assert conn.status == 200
      assert body(conn)["anchored"] == false
    end

    test "an asset already anchored ELSEWHERE cannot be moved → 409" do
      conn =
        MediaController.anchor(upload_conn(@member), %{
          "media_id" => "already-other",
          "conversation_id" => @convo
        })

      assert conn.status == 409
      assert body(conn)["error"]["code"] == "media.already_anchored"
    end

    test "a NON-participant cannot anchor into that conversation → 404 (the leak gate)" do
      conn =
        MediaController.anchor(upload_conn(@stranger), %{
          "media_id" => "unanchored",
          "conversation_id" => @convo
        })

      assert conn.status == 404
    end

    test "missing or blank conversation_id → 400" do
      assert MediaController.anchor(upload_conn(@member), %{"media_id" => "unanchored"}).status ==
               400

      assert MediaController.anchor(upload_conn(@member), %{
               "media_id" => "unanchored",
               "conversation_id" => ""
             }).status == 400
    end

    test "no session → 401" do
      conn = :post |> conn("/api/v1/media/x/anchor", %{})

      assert MediaController.anchor(conn, %{
               "media_id" => "unanchored",
               "conversation_id" => @convo
             }).status ==
               401
    end
  end
end

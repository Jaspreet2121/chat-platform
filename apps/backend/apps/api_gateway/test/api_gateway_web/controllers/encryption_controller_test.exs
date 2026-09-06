defmodule ApiGatewayWeb.EncryptionControllerTest do
  @moduledoc """
  The secret-chat toggle's gateway half (108; two-party OFF in 118), no DB. The store decides; this
  half maps its result to the wire, so what is pinned here is the CONTRACT the clients consume
  verbatim: the one response key-set every 200 carries, the system-message metadata key-set and
  state per change, the conversation_encryption_changed frame key-set on BOTH members' user topics,
  the search purge on a real ON (and ONLY then), silence on an idempotent call, and the error map —
  the store's single refusal atom for unknown/non-member is one 404 body, never a 403.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test

  alias ApiGatewayWeb.EncryptionController
  alias ApiGatewayWeb.SecretChatEvents

  @me "11111111-1111-1111-1111-111111111111"
  @peer "22222222-2222-2222-2222-222222222222"
  @conv "33333333-3333-3333-3333-333333333333"
  @requested_at "2026-09-06T18:00:00Z"

  @response_keys ["e2ee_disabled", "enabled", "off_requested", "requested_at", "requested_by"]
  @frame_keys ["conversation_id", "e2ee_disabled", "e2ee_off_pending", "enabled", "type"]
  @metadata_keys ["by", "kind", "state"]

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer token"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-1111-1111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConversationStub do
    def set_encryption(attrs) do
      send(:enc_test, {:set_encryption, attrs})
      Application.get_env(:api_gateway, :test_set_encryption)
    end

    def secret_conversations_of(_attrs) do
      {:ok,
       %{
         conversation_ids: Application.get_env(:api_gateway, :test_secret_convs, [])
       }}
    end
  end

  defmodule MessageStub do
    def create_message(attrs) do
      send(:enc_test, {:system_message, attrs})
      {:ok, Map.put(attrs, "message_id", "sys-1")}
    end

    def purge_search_index(attrs) do
      send(:enc_test, {:purge_search, attrs})

      case Application.get_env(:api_gateway, :test_purge_result, {:ok, %{purged: 2}}) do
        :raise -> raise "search seam down"
        result -> result
      end
    end
  end

  setup do
    Process.register(self(), :enc_test)

    keys = [
      auth_client_adapter: AuthStub,
      conversation_client_adapter: ConversationStub,
      message_client_adapter: MessageStub
    ]

    previous = for {key, _} <- keys, into: %{}, do: {key, Application.get_env(:shared_infra, key)}
    for {key, value} <- keys, do: Application.put_env(:shared_infra, key, value)

    # Default store answer: a REAL flip to secret.
    Application.put_env(:api_gateway, :test_set_encryption, {:ok, store(%{})})

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end

      for key <- [:test_set_encryption, :test_secret_convs, :test_purge_result],
          do: Application.delete_env(:api_gateway, key)
    end)

    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @peer)
    ApiGatewayWeb.Endpoint.subscribe("conversation:" <> @conv)

    :ok
  end

  # The store's result shape (ConversationService.Encryption.set_encryption/1), overridable per case.
  defp store(overrides) do
    Map.merge(
      %{
        enabled: true,
        already: false,
        change: "enabled",
        member_ids: [@me, @peer],
        e2ee_disabled: false,
        off_pending: nil
      },
      overrides
    )
  end

  defp answer(overrides),
    do: Application.put_env(:api_gateway, :test_set_encryption, {:ok, store(overrides)})

  defp toggle(params) do
    :post
    |> conn("/api/v1/conversations/#{@conv}/encryption", params)
    |> Plug.Conn.put_req_header("authorization", "Bearer token")
    |> EncryptionController.update(Map.put(params, "conversation_id", @conv))
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  defp assert_system_message(state) do
    assert_receive {:system_message, message}
    assert message["message_type"] == "system"
    assert message["sender_user_id"] == @me
    assert message["metadata"] |> Map.keys() |> Enum.sort() == @metadata_keys
    assert message["metadata"] == %{"kind" => "encryption", "state" => state, "by" => @me}

    # ...and its message_created rides the conversation topic (SecretChatEvents' own broadcast).
    assert_receive %Phoenix.Socket.Broadcast{topic: "conversation:" <> @conv, event: "message_created"}
  end

  # ONE frame per member, on the USER topics, identical, key-set pinned.
  defp assert_frame(expected) do
    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @me,
      event: "conversation_encryption_changed",
      payload: mine
    }

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "user:" <> @peer,
      event: "conversation_encryption_changed",
      payload: theirs
    }

    assert Map.keys(mine) |> Enum.sort() == @frame_keys
    assert mine == theirs
    assert mine == Map.merge(%{"type" => "conversation_encryption_changed", "conversation_id" => @conv}, expected)
  end

  defp refute_effects do
    refute_receive {:system_message, _}, 50
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_encryption_changed"}, 50
    refute_receive {:purge_search, _}, 50
  end

  # --- the four request shapes ---------------------------------------------------------------------

  test "ON (real flip): system message, frame on BOTH user topics, search PURGE — response key-set pinned" do
    conn = toggle(%{"enabled" => true})
    assert conn.status == 200

    assert body(conn) |> Map.keys() |> Enum.sort() == @response_keys

    assert body(conn) == %{
             "enabled" => true,
             "e2ee_disabled" => false,
             "off_requested" => false,
             "requested_by" => nil,
             "requested_at" => nil
           }

    # The store received the SESSION identity and the body verbatim (cancel absent → nil).
    assert_receive {:set_encryption, attrs}
    assert attrs["user_id"] == @me
    assert attrs["enabled"] == true
    assert attrs["cancel"] == nil

    assert_system_message("enabled")
    assert_frame(%{"enabled" => true, "e2ee_disabled" => false, "e2ee_off_pending" => nil})

    # MUT-8: 108's promise — the plaintext indexed while plain is purged on a real ON.
    assert_receive {:purge_search, %{"conversation_id" => @conv}}
  end

  test "ON idempotent (change nil): 200 with the same key-set, NOTHING emitted, NO purge" do
    answer(%{already: true, change: nil})

    conn = toggle(%{"enabled" => true})
    assert conn.status == 200
    assert body(conn) |> Map.keys() |> Enum.sort() == @response_keys
    assert body(conn)["enabled"] == true

    refute_effects()
  end

  test "ON that INVALIDATES a pending request: off_cancelled system message + frame, NO purge (already secret)" do
    answer(%{already: true, change: "off_cancelled"})

    conn = toggle(%{"enabled" => true})
    assert conn.status == 200
    assert body(conn)["off_requested"] == false

    assert_system_message("off_cancelled")
    assert_frame(%{"enabled" => true, "e2ee_disabled" => false, "e2ee_off_pending" => nil})
    refute_receive {:purge_search, _}, 50
  end

  test "OFF REQUEST: pending response, off_requested system message, frame carries the pending state, NO purge" do
    answer(%{
      enabled: true,
      already: false,
      change: "off_requested",
      off_pending: %{requested_by: @me, requested_at: @requested_at}
    })

    conn = toggle(%{"enabled" => false})
    assert conn.status == 200
    assert body(conn) |> Map.keys() |> Enum.sort() == @response_keys

    assert body(conn) == %{
             "enabled" => true,
             "e2ee_disabled" => false,
             "off_requested" => true,
             "requested_by" => @me,
             "requested_at" => @requested_at
           }

    assert_receive {:set_encryption, attrs}
    assert attrs["enabled"] == false
    assert attrs["cancel"] == nil

    assert_system_message("off_requested")

    assert_frame(%{
      "enabled" => true,
      "e2ee_disabled" => false,
      "e2ee_off_pending" => %{"requested_by" => @me, "requested_at" => @requested_at}
    })

    refute_receive {:purge_search, _}, 50
  end

  test "OFF ACCEPTED: enabled:false + e2ee_disabled, disabled system message, frame enabled:false, NO purge" do
    answer(%{enabled: false, already: false, change: "disabled", e2ee_disabled: true})

    conn = toggle(%{"enabled" => false})
    assert conn.status == 200

    assert body(conn) == %{
             "enabled" => false,
             "e2ee_disabled" => true,
             "off_requested" => false,
             "requested_by" => nil,
             "requested_at" => nil
           }

    assert_system_message("disabled")
    assert_frame(%{"enabled" => false, "e2ee_disabled" => true, "e2ee_off_pending" => nil})
    refute_receive {:purge_search, _}, 50
  end

  test "OFF by the requester again (store: idempotent pending): the pending shape, NOTHING emitted" do
    answer(%{
      already: true,
      change: nil,
      off_pending: %{requested_by: @me, requested_at: @requested_at}
    })

    conn = toggle(%{"enabled" => false})
    assert conn.status == 200
    assert body(conn)["off_requested"] == true
    assert body(conn)["requested_by"] == @me

    refute_effects()
  end

  test "CANCEL: the store receives cancel:true; off_cancelled system message + frame; NO purge" do
    answer(%{already: false, change: "off_cancelled"})

    conn = toggle(%{"enabled" => false, "cancel" => true})
    assert conn.status == 200
    assert body(conn) == %{
             "enabled" => true,
             "e2ee_disabled" => false,
             "off_requested" => false,
             "requested_by" => nil,
             "requested_at" => nil
           }

    assert_receive {:set_encryption, attrs}
    assert attrs["enabled"] == false
    assert attrs["cancel"] == true

    assert_system_message("off_cancelled")
    assert_frame(%{"enabled" => true, "e2ee_disabled" => false, "e2ee_off_pending" => nil})
    refute_receive {:purge_search, _}, 50
  end

  # --- the purge is best-effort --------------------------------------------------------------------

  test "a FAILED or RAISING search purge never blocks the flip — 200, logged at ERROR" do
    Application.put_env(:api_gateway, :test_purge_result, {:error, :message_unavailable})

    log =
      capture_log(fn ->
        conn = toggle(%{"enabled" => true})
        assert conn.status == 200
        assert body(conn)["enabled"] == true
      end)

    assert_receive {:purge_search, _}
    assert log =~ "[error]"
    assert log =~ "search purge FAILED"
    assert log =~ @conv

    Application.put_env(:api_gateway, :test_purge_result, :raise)

    log =
      capture_log(fn ->
        conn = toggle(%{"enabled" => true})
        assert conn.status == 200
      end)

    assert log =~ "search purge RAISED"
  end

  # --- the error contract --------------------------------------------------------------------------

  test "unknown / non-member / cross-tenant: the store's ONE atom is ONE 404 body (never 403), nothing emitted" do
    Application.put_env(:api_gateway, :test_set_encryption, {:error, :conversation_not_found})

    bodies =
      for params <- [
            %{"enabled" => true},
            %{"enabled" => false},
            %{"enabled" => false, "cancel" => true}
          ] do
        conn = toggle(params)
        # MUT-7 (gateway half): 404, and the same body for every shape.
        assert conn.status == 404
        update_in(body(conn), ["error", "correlation_id"], fn _ -> "X" end)
      end

    assert [_] = Enum.uniq(bodies)
    assert %{"error" => %{"code" => "conversation.not_found"}} = hd(bodies)

    refute_effects()
  end

  test "the rest of the error map: 422 not_supported (+ legacy cannot_disable), 403 not_requester, 400 invalid, 409 names the keyless side" do
    for {error, status, code} <- [
          {{:error, :secret_not_supported}, 422, "secret.not_supported"},
          {{:error, :secret_cannot_disable}, 422, "secret.cannot_disable"},
          {{:error, :secret_not_requester}, 403, "secret.not_requester"},
          {{:error, :secret_invalid}, 400, "secret.invalid"},
          {{:error, :conversation_invalid}, 400, "secret.invalid"}
        ] do
      Application.put_env(:api_gateway, :test_set_encryption, error)
      conn = toggle(%{"enabled" => false})
      assert conn.status == status
      assert %{"error" => %{"code" => ^code}} = body(conn)
    end

    Application.put_env(
      :api_gateway,
      :test_set_encryption,
      {:error, {:secret_peer_keys_missing, [@peer]}}
    )

    conn = toggle(%{"enabled" => true})
    assert conn.status == 409
    assert body(conn)["error"]["code"] == "secret.peer_keys_missing"
    # WHICH side is missing — the client prompts the right person.
    assert body(conn)["error"]["missing_user_ids"] == [@peer]

    refute_effects()
  end

  test "KEYS_CHANGED: one system message per secret conversation; empty set is silent; never raises" do
    Application.put_env(:api_gateway, :test_secret_convs, [
      @conv,
      "77777777-7777-4777-8777-777777777777"
    ])

    assert :ok = SecretChatEvents.emit_keys_changed(@me)

    assert_receive {:system_message, first}
    assert_receive {:system_message, second}
    refute_receive {:system_message, _}, 50

    for message <- [first, second] do
      assert message["message_type"] == "system"

      assert message["metadata"] == %{
               "kind" => "encryption",
               "state" => "keys_changed",
               "user" => @me
             }
    end

    # No secret conversations → nothing written.
    Application.put_env(:api_gateway, :test_secret_convs, [])
    assert :ok = SecretChatEvents.emit_keys_changed(@me)
    refute_receive {:system_message, _}, 50

    # A broken seam never raises out (the triggering operation already succeeded).
    Application.put_env(:shared_infra, :conversation_client_adapter, __MODULE__.Broken)
    assert :ok = SecretChatEvents.emit_keys_changed(@me)
  end

  defmodule Broken do
    def secret_conversations_of(_), do: raise("seam down")
  end
end

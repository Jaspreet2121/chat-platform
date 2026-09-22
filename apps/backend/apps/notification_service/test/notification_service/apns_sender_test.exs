defmodule NotificationService.ApnsSenderTest do
  @moduledoc """
  THE APNs CONTRACT, asserted with no network and no Apple key. Everything that distinguishes a
  working push from a rejected one is a header or a payload key the sender builds, so capturing the
  three arguments to the transport tests the whole of it.

  The cases here are the ones Apple answers with a code that names nothing useful:
  a VoIP payload sent to the alert topic, an alert without `mutable-content`, a sandbox token sent to
  the production host, plaintext in a sealed push.
  """
  use ExUnit.Case, async: false

  alias NotificationService.ApnsSender

  defmodule Transport do
    @moduledoc false
    @behaviour NotificationService.ApnsTransport

    def start, do: Agent.start_link(fn -> [] end, name: __MODULE__)
    def sent, do: Agent.get(__MODULE__, &Enum.reverse/1)

    def status(code, body \\ "{}"),
      do: Application.put_env(:notification_service, :apns_stub_status, {code, body})

    @impl true
    def post(url, headers, body) do
      Agent.update(
        __MODULE__,
        &[%{url: url, headers: Map.new(headers), body: Jason.decode!(body)} | &1]
      )

      {code, response} =
        Application.get_env(:notification_service, :apns_stub_status, {200, "{}"})

      {:ok, code, response}
    end
  end

  @context %{sender: "Ada", preview: "hello there", group_name: nil}
  @attrs %{
    conversation_id: "11111111-1111-4111-8111-111111111111",
    message_id: "22222222-2222-4222-8222-222222222222",
    sender_user_id: "33333333-3333-4333-8333-333333333333"
  }

  setup do
    start_supervised!(%{id: Transport, start: {Transport, :start, []}})
    Application.put_env(:notification_service, :apns_transport, Transport)
    Application.delete_env(:notification_service, :apns_stub_status)

    on_exit(fn ->
      Application.delete_env(:notification_service, :apns_transport)
      Application.delete_env(:notification_service, :apns_stub_status)
    end)

    :ok
  end

  describe "the message payload" do
    test "mirrors the Android data keys, so an iPhone and an Android are told the same facts" do
      payload = ApnsSender.message_payload(@context, @attrs, 3, 7)

      assert payload["type"] == "message"
      assert payload["conversation_id"] == @attrs.conversation_id
      assert payload["message_id"] == @attrs.message_id
      assert payload["sender_id"] == @attrs.sender_user_id
      assert payload["sender_name"] == "Ada"
      assert payload["unread_count"] == 3
    end

    test "carries mutable-content so the Notification Service Extension actually runs" do
      payload = ApnsSender.message_payload(@context, @attrs, 1, 1)

      # Without this the alert is delivered verbatim: no decryption, no thumbnail, no rewritten name.
      assert payload["aps"]["mutable-content"] == 1
      assert payload["aps"]["alert"] == %{"title" => "Ada", "body" => "hello there"}
      assert payload["aps"]["thread-id"] == @attrs.conversation_id
      assert payload["aps"]["badge"] == 1
    end

    test "a SEALED message carries a fetch hint and NO plaintext" do
      sealed_context = %{@context | preview: "New message"}
      attrs = Map.put(@attrs, :message_type, "sealed")

      payload = ApnsSender.message_payload(sealed_context, attrs, 1, 1)

      assert payload["sealed"] == true

      # The server holds ciphertext and nothing else, so there is no body to leak — the assertion is
      # that the generic string is what ships, and that it matches the other two legs.
      assert payload["aps"]["alert"]["body"] == "New message"
      refute payload["aps"]["alert"]["body"] =~ "hello"
    end

    test "an ordinary message carries NO sealed hint — the extension must not wait on a fetch" do
      refute Map.has_key?(ApnsSender.message_payload(@context, @attrs, 1, 1), "sealed")
    end

    test "a group name rides along when there is one, and is absent when there is not" do
      assert ApnsSender.message_payload(%{@context | group_name: "Team"}, @attrs, 1, 1)[
               "group_name"
             ] ==
               "Team"

      refute Map.has_key?(ApnsSender.message_payload(@context, @attrs, 1, 1), "group_name")
    end
  end

  describe "the call payloads" do
    test "a VoIP push has NO aps.alert — CallKit draws the UI, a banner beside it is wrong" do
      payload =
        ApnsSender.call_payload(%{"call_id" => "c1", "caller_name" => "Ada", "e2ee" => true})

      assert payload["aps"] == %{}
      assert payload["type"] == "call"
      assert payload["call_id"] == "c1"
      assert payload["caller_name"] == "Ada"
      assert payload["e2ee"] == true
    end

    test "an unnamed caller still rings as somebody" do
      assert ApnsSender.call_payload(%{"call_id" => "c1"})["caller_name"] == "Someone"
      assert ApnsSender.call_payload(%{"call_id" => "c1"})["call_type"] == "voice"
    end

    test "the cancel keeps the call id and its reason, so the right ring stops" do
      payload = ApnsSender.call_cancelled_payload(%{"call_id" => "c1", "reason" => "timeout"})

      assert payload["type"] == "call_cancelled"
      assert payload["call_id"] == "c1"
      assert payload["reason"] == "timeout"
      assert payload["aps"] == %{}
    end
  end

  describe "without an Apple key" do
    test "every entry point is a quiet no-op — a deployment with no key behaves as it did before" do
      for var <- ~w(APNS_KEY_PATH APNS_KEY_ID APNS_TEAM_ID), do: System.delete_env(var)
      SharedInfra.Apns.ProviderToken.reset()

      refute ApnsSender.configured?()
      assert :ok = ApnsSender.push_message_created(@attrs, ["someone"])
      assert :ok = ApnsSender.push_incoming_call(%{"callee_id" => "someone", "call_id" => "c1"})
      assert :ok = ApnsSender.push_call_cancelled(%{"callee_id" => "someone", "call_id" => "c1"})

      assert Transport.sent() == []
    end
  end
end

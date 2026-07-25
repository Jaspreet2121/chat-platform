defmodule NotificationService.FcmPayloadTest do
  @moduledoc """
  The FCM payload CONTRACT — the exact keys the Android client codes against — plus the
  disabled-when-unconfigured behaviour.

  Deliberately NOT a `DataCase`: none of this touches Postgres, so it must keep running in the
  default (Docker-free) test lane. The delivery tests that DO need rows live in
  `NotificationService.FcmSenderTest`.
  """
  use ExUnit.Case, async: false

  alias NotificationService.FcmSender

  @conversation "71111111-1111-4111-8111-111111111111"
  @sender "72222222-2222-4222-8222-222222222222"
  @recipient "73333333-3333-4333-8333-333333333333"
  @message "74444444-4444-4444-8444-444444444444"
  @token_a "fcm-token-device-a-aaaaaaaaaaaaaaaaaaaaaa"

  defp attrs do
    %{
      event_id: Ecto.UUID.generate(),
      conversation_id: @conversation,
      message_id: @message,
      sender_user_id: @sender,
      created_at: DateTime.utc_now(),
      now: DateTime.utc_now()
    }
  end

  # ---- Payload contract (no infrastructure at all) ----

  describe "data payload" do
    test "a message is DATA-ONLY, with the keys the Android client reads" do
      context = %{sender: "Asha", preview: "📷 Photo", group_name: nil}

      data = FcmSender.message_data(context, attrs(), 3)

      assert data == %{
               "type" => "message",
               "conversation_id" => @conversation,
               "message_id" => @message,
               "sender_id" => @sender,
               "sender_name" => "Asha",
               "preview" => "📷 Photo",
               "unread_count" => "3"
             }

      # Every value is a STRING — FCM rejects a data map containing an integer.
      assert Enum.all?(Map.values(data), &is_binary/1)
    end

    test "a group message carries the group name; a DM has no such key" do
      group =
        FcmSender.message_data(%{sender: "Asha", preview: "hi", group_name: "Team"}, attrs(), 1)

      assert group["group_name"] == "Team"

      dm = FcmSender.message_data(%{sender: "Asha", preview: "hi", group_name: nil}, attrs(), 1)
      refute Map.has_key?(dm, "group_name")
    end

    test "a call carries its own key set" do
      data =
        FcmSender.call_data(%{
          "call_id" => "call-1",
          "call_type" => "video",
          "caller_id" => @sender,
          "caller_name" => "Asha",
          "conversation_id" => @conversation
        })

      assert data == %{
               "type" => "call",
               "call_id" => "call-1",
               "call_type" => "video",
               "caller_id" => @sender,
               "caller_name" => "Asha",
               "conversation_id" => @conversation
             }
    end

    test "a call with no caller name falls back rather than sending an empty string" do
      data = FcmSender.call_data(%{"call_id" => "call-1", "call_type" => nil})

      assert data["caller_name"] == "Someone"
      assert data["call_type"] == "voice"
    end

    test "the envelope is data-only and high priority — NO notification block" do
      envelope = FcmSender.build_envelope(@token_a, %{"type" => "message"})

      assert envelope == %{
               "message" => %{
                 "token" => @token_a,
                 "data" => %{"type" => "message"},
                 "android" => %{"priority" => "high"}
               }
             }

      # THE privacy invariant: a `notification` block would let FCM render the alert itself, and a
      # LOCKED chat's preview would land on the lockscreen with the client powerless to stop it.
      refute Map.has_key?(envelope["message"], "notification")
    end
  end

  describe "configuration" do
    test "is disabled cleanly when no service-account credential is configured" do
      previous = Application.get_env(:notification_service, :fcm)
      Application.delete_env(:notification_service, :fcm)

      on_exit(fn ->
        if previous, do: Application.put_env(:notification_service, :fcm, previous)
      end)

      refute FcmSender.configured?()

      # And the public entry points are no-ops rather than errors — registration keeps working.
      assert :ok = FcmSender.push_message_created(attrs(), [@recipient])
      assert :ok = FcmSender.push_incoming_call(%{"callee_id" => @recipient, "call_id" => "c"})
      refute_receive {:fcm_post, _url, _body, _token}, 50
    end

    test "is disabled when the project id is missing even though credentials are present" do
      previous = Application.get_env(:notification_service, :fcm)

      Application.put_env(:notification_service, :fcm,
        credentials: %{"client_email" => "a@b.c", "private_key" => "x"}
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:notification_service, :fcm, previous),
          else: Application.delete_env(:notification_service, :fcm)
      end)

      refute FcmSender.configured?()
    end
  end
end

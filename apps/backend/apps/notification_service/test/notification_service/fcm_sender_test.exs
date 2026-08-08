defmodule NotificationService.FcmSenderTest do
  @moduledoc """
  The Android push leg.

  DELIVERY: suppression, token fan-out and dead-token pruning against REAL rows
  (`postgres_integration`), with the HTTP transport and the presence markers faked — no test ever
  reaches FCM. The payload contract is infrastructure-free and lives in
  `NotificationService.FcmPayloadTest`.
  """
  use NotificationService.DataCase, async: false

  alias NotificationService.FcmFakes
  alias NotificationService.MessageStoreFixture
  alias NotificationService.FcmSender
  alias NotificationService.Repo

  @conversation "71111111-1111-4111-8111-111111111111"
  @sender "72222222-2222-4222-8222-222222222222"
  @recipient "73333333-3333-4333-8333-333333333333"
  @message "74444444-4444-4444-8444-444444444444"
  @token_a "fcm-token-device-a-aaaaaaaaaaaaaaaaaaaaaa"
  @token_b "fcm-token-device-b-bbbbbbbbbbbbbbbbbbbbbb"

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

  # ---- Delivery (real rows; faked transport + presence) ----

  describe "delivery" do
    setup context do
      FcmFakes.configure!(context)

      # The preview no longer comes from this app's Repo — it is read from the message STORE through
      # SharedInfra.MessageClient. Without a reachable store every delivery test below sends NOTHING,
      # because an unreadable message now suppresses the push instead of saying "New message".
      MessageStoreFixture.start!()
      :ok
    end

    @tag :postgres_integration
    test "an ABSENT message sends NO push — not one whose body says \"New message\"" do
      # Everything a push needs EXCEPT the message: registered devices, an unmuted recipient, nobody
      # present. seed_message! is deliberately not called, so the store read returns not-found.
      seed_tokens!([@token_a])

      FcmSender.deliver(attrs(), [@recipient])

      # The old behaviour reached FCM with "New message". Silence is the fix: a notification that
      # lies about its content is worse than no notification, because it looks like it worked.
      refute_receive {:fcm_post, _url, _body, _token}, 300
    end

    @tag :postgres_integration
    test "sends one data message per registered device, to the right URL" do
      seed_message!()
      seed_tokens!([@token_a, @token_b])

      FcmSender.deliver(attrs(), [@recipient])

      assert_receive {:fcm_post, url, body, "test-access-token"}
      assert url == "https://fcm.googleapis.com/v1/projects/test-project/messages:send"
      assert %{"message" => %{"data" => data, "android" => %{"priority" => "high"}}} = body
      assert data["type"] == "message"
      assert data["conversation_id"] == @conversation

      # The preview is PushContext's — the same string the web leg puts in its notification body.
      assert data["preview"] == "hello from the seed"

      # Exactly one send per registered device, and no third.
      assert_receive {:fcm_post, _url, %{"message" => %{"token" => second_token}}, _token}

      assert Enum.sort([body["message"]["token"], second_token]) ==
               Enum.sort([@token_a, @token_b])

      refute_receive {:fcm_post, _url, _body, _token}, 100
    end

    @tag :postgres_integration
    test "a recipient with no registered device is simply skipped" do
      seed_message!()

      FcmSender.deliver(attrs(), [@recipient])

      refute_receive {:fcm_post, _url, _body, _token}, 100
    end

    @tag presence: FcmFakes.PresentEverywhere
    @tag :postgres_integration
    test "suppressed when the recipient's app is foreground anywhere" do
      seed_message!()
      seed_tokens!([@token_a])

      FcmSender.deliver(attrs(), [@recipient])

      refute_receive {:fcm_post, _url, _body, _token}, 100
    end

    @tag presence: FcmFakes.ViewingThisChat
    @tag :postgres_integration
    test "suppressed when the recipient is viewing THIS conversation" do
      seed_message!()
      seed_tokens!([@token_a])

      FcmSender.deliver(attrs(), [@recipient])

      refute_receive {:fcm_post, _url, _body, _token}, 100
    end

    @tag :postgres_integration
    test "suppressed when the conversation is muted for that recipient" do
      seed_message!()
      seed_tokens!([@token_a])
      mute!()

      FcmSender.deliver(attrs(), [@recipient])

      refute_receive {:fcm_post, _url, _body, _token}, 100
    end

    @tag :postgres_integration
    test "UNREGISTERED prunes the dead token row" do
      seed_message!()
      seed_tokens!([@token_a])

      FcmFakes.respond_with([
        {:ok, %{status: 404, body: %{"error" => %{"status" => "UNREGISTERED"}}}}
      ])

      FcmSender.deliver(attrs(), [@recipient])

      assert_receive {:fcm_post, _url, _body, _token}
      assert token_count(@token_a) == 0
    end

    @tag :postgres_integration
    test "INVALID_ARGUMENT prunes too; an unrelated 500 does NOT" do
      seed_message!()
      seed_tokens!([@token_a])

      FcmFakes.respond_with([
        {:ok, %{status: 400, body: %{"error" => %{"status" => "INVALID_ARGUMENT"}}}}
      ])

      FcmSender.deliver(attrs(), [@recipient])
      assert token_count(@token_a) == 0

      seed_tokens!([@token_a])

      FcmFakes.respond_with([
        {:ok, %{status: 500, body: %{"error" => %{"status" => "INTERNAL"}}}}
      ])

      FcmSender.deliver(attrs(), [@recipient])
      # A transient server error is NOT a dead device — the row stays.
      assert token_count(@token_a) == 1
    end

    @tag :postgres_integration
    test "a call push reaches a backgrounded callee's devices" do
      seed_tokens!([@token_a])

      FcmSender.deliver_call(
        %{
          "call_id" => "call-9",
          "call_type" => "voice",
          "caller_id" => @sender,
          "caller_name" => "Asha"
        },
        @recipient
      )

      assert_receive {:fcm_post, _url, %{"message" => %{"data" => data}}, _token}
      assert data["type"] == "call"
      assert data["call_id"] == "call-9"
    end

    @tag presence: FcmFakes.PresentEverywhere
    @tag :postgres_integration
    test "a call push is suppressed for a FOREGROUND callee (they already got the socket ring)" do
      seed_tokens!([@token_a])

      FcmSender.deliver_call(%{"call_id" => "call-9", "call_type" => "voice"}, @recipient)

      refute_receive {:fcm_post, _url, _body, _token}, 100
    end
  end

  # ---- Seeding ----

  defp seed_message! do
    # FIRST, and through MessageService.Repo: the message must be readable by the message STORE, which
    # is a different connection from this app's sandboxed Repo. Committing the shared parent rows
    # (users_auth, conversations) before the sandbox touches the same primary keys is what stops the
    # two connections blocking on each other.
    MessageStoreFixture.insert_message!(@conversation, @message, @sender,
      body: "hello from the seed",
      conversation_type: "direct"
    )

    Repo.query!(
      "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2), ($3::text::uuid, $4) " <>
        "ON CONFLICT DO NOTHING",
      [@sender, "+917111111111", @recipient, "+917222222222"]
    )

    Repo.query!(
      "INSERT INTO user_profiles (user_id, display_name) VALUES ($1::text::uuid, $2) " <>
        "ON CONFLICT (user_id) DO UPDATE SET display_name = EXCLUDED.display_name",
      [@sender, "Asha"]
    )

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid) ON CONFLICT DO NOTHING",
      [@conversation, @sender]
    )

    Repo.query!(
      "INSERT INTO conversation_participants (conversation_id, user_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid) ON CONFLICT DO NOTHING",
      [@conversation, @recipient]
    )
  end

  defp seed_tokens!(tokens) do
    Repo.query!(
      "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2) ON CONFLICT DO NOTHING",
      [@recipient, "+917222222222"]
    )

    Enum.each(tokens, fn token ->
      Repo.query!(
        "INSERT INTO fcm_tokens (user_id, token) VALUES ($1::text::uuid, $2) " <>
          "ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id",
        [@recipient, token]
      )
    end)
  end

  defp mute! do
    Repo.query!(
      "UPDATE conversation_participants SET muted_until = now() + interval '1 hour' " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [@conversation, @recipient]
    )
  end

  defp token_count(token) do
    %{rows: [[n]]} = Repo.query!("SELECT count(*) FROM fcm_tokens WHERE token = $1", [token])
    n
  end
end

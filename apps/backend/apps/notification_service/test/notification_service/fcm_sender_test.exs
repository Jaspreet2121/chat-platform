defmodule NotificationService.FcmSenderTest do
  @moduledoc """
  The Android push leg.

  DELIVERY: suppression, token fan-out and dead-token pruning against REAL rows
  (`postgres_integration`), with the HTTP transport and the presence markers faked — no test ever
  reaches FCM. The payload contract is infrastructure-free and lives in
  `NotificationService.FcmPayloadTest`.
  """
  use NotificationService.DataCase, async: false

  import ExUnit.CaptureLog

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
  # An APNs device token: 64 hex characters, nothing FCM would ever accept.
  @ios_token "0f0e0d0c0b0a09080706050403020100ffeeddccbbaa99887766554433221100"

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

  # ---- The stale-ring cutoff (pure; no DB) ----

  test "a group ring's ttl comes from ring_deadline_at; a direct ring keeps the 35s window" do
    deadline = DateTime.utc_now() |> DateTime.add(20, :second) |> DateTime.to_iso8601()
    assert FcmSender.call_ttl(%{"ring_deadline_at" => deadline}) in ["19s", "20s"]
    assert FcmSender.call_ttl(%{}) == "35s"
    # A deadline already in the past never yields "0s" (FCM rejects it) — 1s, deliver-or-die.
    past = DateTime.utc_now() |> DateTime.add(-5, :second) |> DateTime.to_iso8601()
    assert FcmSender.call_ttl(%{"ring_deadline_at" => past}) == "1s"
    # kind rides the data so the client can pick the group UI.
    assert FcmSender.call_data(%{"call_id" => "g1", "kind" => "adhoc"})["kind"] == "adhoc"
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

    # THE REAL FCM v1 404 BODY, verbatim. "UNREGISTERED" is NOT at error.status — it lives one level
    # down in details[].errorCode, and error.status is "NOT_FOUND". The fixture this replaced was
    # hand-typed as %{"error" => %{"status" => "UNREGISTERED"}}, a shape FCM never emits, so the
    # suite certified a prune that could not fire in production: two dead tokens for one user were
    # re-sent to on every message for three weeks, logging "fcm rejected (404)" each time.
    @unregistered_404 %{
      "error" => %{
        "code" => 404,
        "message" => "Requested entity was not found.",
        "status" => "NOT_FOUND",
        "details" => [
          %{
            "@type" => "type.googleapis.com/google.firebase.fcm.v1.FcmError",
            "errorCode" => "UNREGISTERED"
          }
        ]
      }
    }

    @tag :postgres_integration
    test "a REAL FCM 404 prunes the dead token row" do
      seed_message!()
      seed_tokens!([@token_a])

      FcmFakes.respond_with([{:ok, %{status: 404, body: @unregistered_404}}])

      FcmSender.deliver(attrs(), [@recipient])

      assert_receive {:fcm_post, _url, _body, _token}

      assert token_count(@token_a) == 0,
             "a token FCM answered 404 for is still in the table — every later message re-sends " <>
               "to a device that can never receive it"
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
    test "an iOS row is NEITHER sent to FCM NOR pruned when FCM rejects the Android one" do
      # Since 129 fcm_tokens holds APNs tokens too (platform = 'ios'). FCM answers a non-FCM token
      # with 400 INVALID_ARGUMENT, which is exactly the shape prune keys on — so before the platform
      # filter, one Android push deleted the same user's iPhone registrations. Seed both platforms for
      # one user, make FCM reject everything it is sent, and prove the iOS row is untouched.
      seed_message!()
      seed_tokens!([@token_a])
      seed_ios_token!(@ios_token, "iphone-1")

      FcmFakes.respond_with([
        {:ok, %{status: 400, body: %{"error" => %{"status" => "INVALID_ARGUMENT"}}}}
      ])

      FcmSender.deliver(attrs(), [@recipient])

      # Exactly one post, and it carried the Android token — the iOS token never left the box.
      # (The 4th element is the FCM ACCESS token; the device token rides in message.token.)
      assert_receive {:fcm_post, _url, %{"message" => %{"token" => @token_a}}, _access}, 500
      refute_receive {:fcm_post, _url, %{"message" => %{"token" => @ios_token}}, _access}, 200

      # The Android row was rightly pruned on the 400; the iOS row was never a candidate.
      assert token_count(@token_a) == 0
      assert token_count(@ios_token) == 1
    end

    @tag :postgres_integration
    test "a 500 carrying the IDENTICAL body does NOT prune — only the status decides" do
      seed_message!()
      seed_tokens!([@token_a])

      # Byte-for-byte the 404 body, behind a 500. A transient server error is not a dead device, and
      # the difference between the two is the status — which is exactly why the rule reads it.
      FcmFakes.respond_with([{:ok, %{status: 500, body: @unregistered_404}}])

      FcmSender.deliver(attrs(), [@recipient])

      assert_receive {:fcm_post, _url, _body, _token}

      assert token_count(@token_a) == 1,
             "a 500 pruned the token — an FCM outage would delete the fleet's registrations"
    end

    @tag :postgres_integration
    test "410 prunes as well as 404 — the web leg's rule, unchanged" do
      seed_message!()
      seed_tokens!([@token_a])

      FcmFakes.respond_with([{:ok, %{status: 410, body: %{}}}])

      FcmSender.deliver(attrs(), [@recipient])
      assert token_count(@token_a) == 0
    end

    # ---- every outcome names itself -------------------------------------------------------------

    @tag :postgres_integration
    test "SUCCESS logs user, device and FCM's message name — the path that used to be silent" do
      seed_message!()
      seed_device_token!(@token_a, "android-a7a76c7a")

      FcmFakes.respond_with([
        {:ok, %{status: 200, body: %{"name" => "projects/p/messages/0:169"}}}
      ])

      log = capture_log([level: :info], fn -> FcmSender.deliver(attrs(), [@recipient]) end)

      assert log =~
               "fcm sent user=#{@recipient} device=android-a7a76c7a name=projects/p/messages/0:169",
             "a successful send logged nothing — 'was this device sent to, or skipped?' is then " <>
               "unanswerable from the log, which is what cost an entire inspection"
    end

    @tag :postgres_integration
    test "PRUNE logs the user, device and status it pruned on" do
      seed_message!()
      seed_device_token!(@token_a, "android-c2b03c8c")

      FcmFakes.respond_with([{:ok, %{status: 404, body: @unregistered_404}}])

      log = capture_log([level: :info], fn -> FcmSender.deliver(attrs(), [@recipient]) end)

      assert log =~ "fcm token pruned user=#{@recipient} device=android-c2b03c8c status=404",
             "a token vanished from the table with no log line — a silent delete is how you lose " <>
               "the ability to explain a device that stopped receiving"
    end

    @tag presence: FcmFakes.PresentEverywhere
    @tag :postgres_integration
    test "SKIP logs its reason — app_present" do
      seed_message!()
      seed_tokens!([@token_a])

      log = capture_log([level: :info], fn -> FcmSender.deliver(attrs(), [@recipient]) end)

      assert log =~ "fcm skipped user=#{@recipient} reason=app_present",
             "a suppressed recipient left no trace — indistinguishable from a send that was never " <>
               "attempted"

      refute_receive {:fcm_post, _url, _body, _token}, 100
    end

    @tag presence: FcmFakes.ViewingThisChat
    @tag :postgres_integration
    test "SKIP logs its reason — viewing_conversation" do
      seed_message!()
      seed_tokens!([@token_a])

      log = capture_log([level: :info], fn -> FcmSender.deliver(attrs(), [@recipient]) end)
      assert log =~ "reason=viewing_conversation"
    end

    @tag :postgres_integration
    test "SKIP logs its reason — muted" do
      seed_message!()
      seed_tokens!([@token_a])
      mute!()

      log = capture_log([level: :info], fn -> FcmSender.deliver(attrs(), [@recipient]) end)
      assert log =~ "reason=muted"
    end

    @tag :postgres_integration
    test "SKIP logs its reason — no_tokens (registered nothing, or everything was pruned)" do
      seed_message!()

      log = capture_log([level: :info], fn -> FcmSender.deliver(attrs(), [@recipient]) end)
      assert log =~ "fcm skipped user=#{@recipient} reason=no_tokens"
    end

    @tag presence: FcmFakes.PresentEverywhere
    @tag :postgres_integration
    test "SKIP logs its reason — call_callee_foreground" do
      seed_tokens!([@token_a])

      log =
        capture_log([level: :info], fn ->
          FcmSender.deliver_call(%{"call_id" => "call-9", "callee_id" => @recipient}, @recipient)
        end)

      assert log =~ "fcm skipped user=#{@recipient} reason=call_callee_foreground"
    end

    @tag :postgres_integration
    test "a NON-fatal rejection keeps the existing line, now naming the user and device" do
      seed_message!()
      seed_device_token!(@token_a, "android-ceb80ff9")

      FcmFakes.respond_with([
        {:ok, %{status: 429, body: %{"error" => %{"status" => "RESOURCE_EXHAUSTED"}}}}
      ])

      log = capture_log(fn -> FcmSender.deliver(attrs(), [@recipient]) end)

      assert log =~ "fcm rejected (429) user=#{@recipient} device=android-ceb80ff9"
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

      assert_receive {:fcm_post, _url, %{"message" => %{"data" => data} = message}, _token}
      assert data["type"] == "call"
      assert data["call_id"] == "call-9"

      # The ring carries the collapse key its stop will reuse (a pending ring is superseded by cancel)
      # AND a TTL equal to the server ring timeout (CallSignaling: 35s) — a delivery FCM can't make
      # inside the ring window dies in transit instead of ringing a dead call late (the MIUI case).
      assert message["android"]["priority"] == "high"
      assert message["android"]["ttl"] == "35s"
      assert message["android"]["collapse_key"] == "call_call-9"
    end

    @tag presence: FcmFakes.PresentEverywhere
    @tag :postgres_integration
    test "call.cancelled pushes UNSUPPRESSED (even foreground) with ttl + collapse_key" do
      seed_tokens!([@token_a])

      # PresentEverywhere: the incoming leg would suppress — the STOP must not (a redundant stop is an
      # idempotent no-op on the client; a suppressed one leaves a dead ring on the handset).
      FcmSender.deliver_call_cancelled(
        %{"call_id" => "call-9", "reason" => "cancelled"},
        @recipient
      )

      assert_receive {:fcm_post, _url, %{"message" => message}, _token}

      assert message["data"] == %{
               "type" => "call_cancelled",
               "call_id" => "call-9",
               "reason" => "cancelled"
             }

      assert message["android"]["priority"] == "high"
      assert message["android"]["ttl"] == "60s"
      assert message["android"]["collapse_key"] == "call_call-9"
    end

    @tag :postgres_integration
    test "call.cancelled with no tokens is a clean no-op" do
      FcmSender.deliver_call_cancelled(%{"call_id" => "call-9"}, @recipient)
      refute_receive {:fcm_post, _url, _body, _token}, 100
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

    # device_id is NOT NULL since 121 (one row per device) — derive one per token.
    Enum.each(tokens, fn token -> seed_device_token!(token, "device-of-" <> token) end)
  end

  # seed_tokens!/1 with a chosen device id, for the tests that assert it in a log line.
  defp seed_device_token!(token, device_id) do
    Repo.query!(
      "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2) ON CONFLICT DO NOTHING",
      [@recipient, "+917222222222"]
    )

    Repo.query!(
      "INSERT INTO fcm_tokens (user_id, token, device_id) VALUES ($1::text::uuid, $2, $3) " <>
        "ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, device_id = EXCLUDED.device_id",
      [@recipient, token, device_id]
    )
  end

  # An iPhone's alert-channel row for the same recipient (129: platform 'ios', kind 'alert').
  defp seed_ios_token!(token, device_id) do
    Repo.query!(
      "INSERT INTO fcm_tokens (user_id, token, device_id, platform, kind, environment) " <>
        "VALUES ($1::text::uuid, $2, $3, 'ios', 'alert', 'sandbox') " <>
        "ON CONFLICT (token) DO UPDATE SET user_id = EXCLUDED.user_id, device_id = EXCLUDED.device_id",
      [@recipient, token, device_id]
    )
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

defmodule ConversationService.CallWebhooksTest do
  @moduledoc """
  `call.*` webhooks on the CallStore lifecycle transitions.

  DB-backed (`@tag :postgres_integration`): the things worth testing here are the tenant derivation (calls
  have NO app_id column), the external-id resolution, and the atomicity of the emit with the status change —
  all of which are SQL. A stubbed repo would only test the stub.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.CallStore

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  # --- fixtures ---

  defp app!(name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug, created_at, updated_at) VALUES ($1::text::uuid, $2, $3, now(), now())",
      [id, name, "slug-#{id}"]
    )

    id
  end

  defp user!(app_id, external_id) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO users_auth (id, app_id, external_id, password_hash, created_at, updated_at)
      VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())
      """,
      [id, app_id, external_id]
    )

    id
  end

  # An enabled endpoint subscribed to `events` — WebhookOutbox.emit only writes for a MATCHING subscription.
  defp endpoint!(app_id, events) do
    id = Ecto.UUID.generate()

    Repo.query!(
      """
      INSERT INTO webhook_endpoints (id, app_id, url, signing_secret, event_types, enabled, created_at, updated_at)
      VALUES ($1::text::uuid, $2::text::uuid, 'https://example.test/hook', 'secret', $3, true, now(), now())
      """,
      [id, app_id, events]
    )

    id
  end

  defp call!(caller_id, callee_id, opts \\ []) do
    {:ok, call} =
      CallStore.create_call(%{
        "caller_id" => caller_id,
        "callee_id" => callee_id,
        "type" => Keyword.get(opts, :type, "voice"),
        "conversation_id" => Keyword.get(opts, :conversation_id)
      })

    call.id
  end

  defp outbox(app_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT event_type, payload, app_id::text FROM webhook_outbox WHERE app_id = $1::text::uuid ORDER BY created_at",
        [app_id]
      )

    Enum.map(rows, fn [event_type, payload, row_app_id] ->
      %{event_type: event_type, payload: decode_payload(payload), app_id: row_app_id}
    end)
  end

  # jsonb comes back from a raw Repo.query! as text on this Repo (no jsonb decoder configured for raw
  # queries) — decode it so the assertions read against the real payload.
  defp decode_payload(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode_payload(payload) when is_map(payload), do: payload

  defp setup_app(events \\ ["call.started", "call.ended", "call.missed", "call.declined"]) do
    app_id = app!("app-#{Ecto.UUID.generate()}")
    endpoint!(app_id, events)
    caller = user!(app_id, "alice_ext")
    callee = user!(app_id, "bob_ext")
    {app_id, caller, callee}
  end

  # --- tests ---

  @tag :postgres_integration
  test "the SHARED ConversationClient path (what /v1 accept calls) emits call.started" do
    # /v1 CallController.accept calls SharedInfra.ConversationClient.mark_call_answered — NOT CallStore
    # directly. This asserts the in-process adapter delegates to the emitting path, closing the composition:
    # controller → ConversationClient.mark_call_answered → CallStore.mark_answered → webhook. (The controller's
    # authz/guard live in ApiGatewayWeb.V1.CallAcceptRejectTest.)
    {app_id, caller, callee} = setup_app()
    call_id = call!(caller, callee)

    assert {:ok, _} = SharedInfra.ConversationClient.mark_call_answered(%{"call_id" => call_id})
    assert [%{event_type: "call.started", app_id: ^app_id}] = outbox(app_id)

    # And reject via the same client surface emits call.declined.
    {app_id2, caller2, callee2} = setup_app()
    call_id2 = call!(caller2, callee2)
    assert {:ok, _} = SharedInfra.ConversationClient.mark_call_declined(%{"call_id" => call_id2})
    assert [%{event_type: "call.declined"}] = outbox(app_id2)
  end

  @tag :postgres_integration
  test "expected_status guard: answering a non-ringing call is refused ATOMICALLY, emits NO webhook" do
    # This is the race-closer the /v1 accept path relies on (a row-locked source-status re-check), independent
    # of the controller's fast-path check. A call that already ended must not be un-ended NOR re-emit
    # call.started, even if the caller passes expected_status="ringing".
    {app_id, caller, callee} = setup_app()
    call_id = call!(caller, callee)

    # Drive it to ended first (emits call.ended).
    assert {:ok, _} = CallStore.mark_answered(%{"call_id" => call_id})
    assert {:ok, _} = CallStore.mark_ended(%{"call_id" => call_id})

    before = outbox(app_id)

    # Now an accept WITH the precondition: the current status is "ended", not "ringing" → conflict, no write.
    assert {:error, :call_conflict} =
             CallStore.mark_answered(%{"call_id" => call_id, "expected_status" => "ringing"})

    # No new webhook, and the call is still ended (never resurrected to accepted).
    assert outbox(app_id) == before

    assert %{rows: [["ended"]]} =
             Repo.query!("SELECT status FROM calls WHERE id = $1::text::uuid", [call_id])
  end

  @tag :postgres_integration
  test "expected_status guard: a MATCHING status (ringing) still transitions + emits normally" do
    {app_id, caller, callee} = setup_app()
    call_id = call!(caller, callee)

    # Ringing, precondition matches → the accept goes through and emits call.started, exactly as the plain path.
    assert {:ok, _} =
             CallStore.mark_answered(%{"call_id" => call_id, "expected_status" => "ringing"})

    assert [%{event_type: "call.started"}] = outbox(app_id)
  end

  @tag :postgres_integration
  test "answered → call.started, tenant-scoped, with EXTERNAL ids (never internal uuids)" do
    {app_id, caller, callee} = setup_app()
    call_id = call!(caller, callee, type: "video")

    assert {:ok, _} = CallStore.mark_answered(%{"call_id" => call_id})

    assert [%{event_type: "call.started", payload: payload, app_id: ^app_id}] = outbox(app_id)
    assert payload["call_id"] == call_id
    assert payload["type"] == "video"
    assert payload["kind"] == "direct"

    # The integrator speaks EXTERNAL ids — an internal uuid would be meaningless to them.
    assert payload["caller_external_id"] == "alice_ext"
    assert payload["callee_external_id"] == "bob_ext"

    # Answered but not ended → started_at set, no duration yet.
    assert is_binary(payload["started_at"])
    assert payload["duration_seconds"] == nil
  end

  @tag :postgres_integration
  test "ended → call.ended with duration_seconds = ended - answered" do
    {app_id, caller, callee} = setup_app()
    call_id = call!(caller, callee)

    assert {:ok, _} = CallStore.mark_answered(%{"call_id" => call_id})
    # Backdate the answer so the duration is a real, non-zero number.
    Repo.query!(
      "UPDATE calls SET answered_at = now() - interval '42 seconds' WHERE id = $1::text::uuid",
      [call_id]
    )

    assert {:ok, _} = CallStore.mark_ended(%{"call_id" => call_id})

    events = outbox(app_id)
    assert Enum.map(events, & &1.event_type) == ["call.started", "call.ended"]

    ended = List.last(events).payload
    assert ended["reason"] == "ended"
    assert is_binary(ended["ended_at"])
    # ~42s, allowing a second of slack for the test's own clock.
    assert ended["duration_seconds"] >= 41 and ended["duration_seconds"] <= 44
  end

  @tag :postgres_integration
  test "missed → call.missed with NO duration (it was never connected)" do
    {app_id, caller, callee} = setup_app()
    call_id = call!(caller, callee)

    assert {:ok, _} = CallStore.mark_missed(%{"call_id" => call_id})

    assert [%{event_type: "call.missed", payload: payload}] = outbox(app_id)
    assert payload["duration_seconds"] == nil
    assert payload["started_at"] == nil
    assert payload["reason"] == "missed"
  end

  @tag :postgres_integration
  test "declined → call.declined, a SEPARATE type from missed (active refusal vs timeout)" do
    {app_id, caller, callee} = setup_app()
    call_id = call!(caller, callee)

    assert {:ok, _} = CallStore.mark_declined(%{"call_id" => call_id})

    assert [%{event_type: "call.declined", payload: payload}] = outbox(app_id)
    assert payload["duration_seconds"] == nil
    assert payload["reason"] == "declined"
  end

  @tag :postgres_integration
  test "TENANT SCOPE: a call in app X never emits to app Y's endpoint" do
    {app_x, caller, callee} = setup_app()
    app_y = app!("other-tenant")
    endpoint!(app_y, ["call.started", "call.ended"])

    call_id = call!(caller, callee)
    assert {:ok, _} = CallStore.mark_answered(%{"call_id" => call_id})

    # App X's endpoint got it…
    assert [%{event_type: "call.started"}] = outbox(app_x)
    # …and the OTHER tenant's endpoint got nothing at all.
    assert outbox(app_y) == []
  end

  @tag :postgres_integration
  test "the payload carries NO room token / room_name / media — metadata only" do
    {app_id, caller, callee} = setup_app()
    call_id = call!(caller, callee)
    CallStore.mark_answered(%{"call_id" => call_id})

    [%{payload: payload}] = outbox(app_id)

    # The room name IS the join handle for LiveKit — it must never leave the platform.
    refute Map.has_key?(payload, "room_name")
    refute Map.has_key?(payload, "room")
    refute Map.has_key?(payload, "token")
    refute Map.has_key?(payload, "media_id")

    assert Map.keys(payload) |> Enum.sort() == [
             "call_id",
             "callee_external_id",
             "caller_external_id",
             "conversation_id",
             "duration_seconds",
             "ended_at",
             "kind",
             "reason",
             "started_at",
             "type"
           ]
  end

  @tag :postgres_integration
  test "ATOMIC: a transition that does not happen emits NOTHING" do
    {app_id, _caller, _callee} = setup_app()

    # An unknown call never transitions → no webhook may exist for it.
    assert {:error, :call_not_found} = CallStore.mark_ended(%{"call_id" => Ecto.UUID.generate()})
    assert outbox(app_id) == []
  end

  @tag :postgres_integration
  test "an endpoint NOT subscribed to call.* receives nothing (subscription is honoured)" do
    app_id = app!("selective")
    endpoint!(app_id, ["message.created"])
    caller = user!(app_id, "alice_ext")
    callee = user!(app_id, "bob_ext")

    call_id = call!(caller, callee)
    assert {:ok, _} = CallStore.mark_answered(%{"call_id" => call_id})

    assert outbox(app_id) == []
  end

  @tag :postgres_integration
  test "a LINK call (conversation_id NULL) still resolves its tenant — the reason app_id comes from the caller" do
    {app_id, caller, callee} = setup_app()

    # No conversation at all: this is exactly the case that a conversation-derived app_id would have dropped.
    call_id = call!(caller, callee, conversation_id: nil)
    assert {:ok, _} = CallStore.mark_answered(%{"call_id" => call_id})

    assert [%{event_type: "call.started", payload: payload, app_id: ^app_id}] = outbox(app_id)
    assert payload["conversation_id"] == nil
  end
end

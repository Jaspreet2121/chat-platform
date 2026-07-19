defmodule MessageService.MessageWebhooksTest do
  @moduledoc """
  The `message.created` webhook payload — EXTERNAL ids only. The integrator refers to their users by their
  own external ids everywhere (token minting, /v1); an internal uuid in a webhook is meaningless to them and
  a boundary leak. These prove: the sender emits as `sender_external_id`, an unresolvable sender DROPS the
  event (never internal/blank), resolution keys on the CONVERSATION's app_id (not a caller-supplied one),
  and the delivered envelope's `created_at` is ISO 8601.

  DB-backed (the resolution and the outbox ARE SQL) — opt-in like every other Postgres test.
  """
  use MessageService.DataCase, async: false

  @moduletag :postgres_integration

  alias MessageService.MessageStore.PostgresAdapter

  defp app! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO apps (id, name, slug, created_at, updated_at) VALUES ($1::text::uuid, $2, $3, now(), now())",
      [id, "app-#{id}", "slug-#{id}"]
    )

    id
  end

  defp user!(app_id, external_id) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, external_id, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, app_id, external_id]
    )

    id
  end

  # A FIRST-PARTY-style user: no external_id (the identity check then requires an email).
  defp user_without_external!(app_id) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, app_id, "noext-#{id}@test.local"]
    )

    id
  end

  defp conversation!(app_id, created_by) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, 'direct', $2::text::uuid, 'active', $3::text::uuid, now(), now())",
      [id, created_by, app_id]
    )

    id
  end

  defp endpoint!(app_id, events) do
    Repo.query!(
      "INSERT INTO webhook_endpoints (id, app_id, url, signing_secret, event_types, enabled, created_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, 'https://example.test/hook', 'secret', $2, true, now(), now())",
      [app_id, events]
    )
  end

  defp outbox(app_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT event_type, payload FROM webhook_outbox WHERE app_id = $1::text::uuid ORDER BY created_at",
        [app_id]
      )

    Enum.map(rows, fn [event_type, payload] -> %{event_type: event_type, payload: decode(payload)} end)
  end

  defp decode(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode(payload) when is_map(payload), do: payload

  defp send_message!(conversation_id, sender_id, body, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          "message_id" => Ecto.UUID.generate(),
          "conversation_id" => conversation_id,
          "sender_user_id" => sender_id,
          "message_type" => "text",
          "body" => body,
          "created_at" => DateTime.utc_now()
        },
        extra
      )

    PostgresAdapter.put_message(attrs)
  end

  test "message.created carries sender_EXTERNAL_id — never the internal uuid" do
    app = app!()
    endpoint!(app, ["message.created"])
    sender = user!(app, "alice_ext")
    conv = conversation!(app, sender)

    assert {:ok, _} = send_message!(conv, sender, "hello integrator")

    assert [%{event_type: "message.created", payload: payload}] = outbox(app)
    assert payload["sender_external_id"] == "alice_ext"
    refute Map.has_key?(payload, "sender_user_id")
    # The message/conversation ids legitimately stay uuids (resource ids, not user ids)…
    assert payload["conversation_id"] == conv
    assert is_binary(payload["message_id"])
    # …but the sender's INTERNAL uuid must not appear ANYWHERE in the emitted JSON.
    refute Jason.encode!(payload) =~ sender
    # Inner created_at is ISO 8601.
    assert {:ok, _, _} = DateTime.from_iso8601(payload["created_at"])
  end

  test "an unresolvable sender (no external_id) → the message persists but the webhook is DROPPED" do
    app = app!()
    endpoint!(app, ["message.created"])
    sender = user_without_external!(app)
    conv = conversation!(app, sender)

    # The write itself must not fail — only the (unattributable) event is suppressed.
    assert {:ok, _} = send_message!(conv, sender, "first-party message")
    assert outbox(app) == []
  end

  test "resolution keys on the CONVERSATION's app_id — a caller-supplied wrong app_id can't move or break it" do
    app = app!()
    other_app = app!()
    endpoint!(app, ["message.created"])
    endpoint!(other_app, ["message.created"])
    sender = user!(app, "alice_ext")
    conv = conversation!(app, sender)

    # The attrs LIE about the tenant. put_message stamps the conversation's app_id over it, and the
    # sender still resolves under the conversation's tenant.
    assert {:ok, _} = send_message!(conv, sender, "hi", %{"app_id" => other_app})

    assert [%{payload: %{"sender_external_id" => "alice_ext"}}] = outbox(app)
    # …and nothing leaked to the lied-about tenant.
    assert outbox(other_app) == []
  end

  test "the delivered ENVELOPE's created_at is ISO 8601 (claim_due — what build_body receives)" do
    app = app!()
    endpoint!(app, ["message.created"])
    sender = user!(app, "alice_ext")
    conv = conversation!(app, sender)
    assert {:ok, _} = send_message!(conv, sender, "iso check")

    assert [row] = SharedInfra.WebhookOutbox.claim_due(Repo, 10)
    assert {:ok, _, _} = DateTime.from_iso8601(row.created_at)
  end
end

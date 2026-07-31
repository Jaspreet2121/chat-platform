defmodule ConversationService.ConversationCreatedWebhookTest do
  @moduledoc """
  The `conversation.created` webhook payload — EXTERNAL ids only, batch-resolved in ONE query. Drop rule:
  an unresolvable CREATOR drops the whole event (attribution); an unresolvable PARTICIPANT is omitted but
  the event still emits (enumeration). No internal user uuid may appear in the emitted JSON.
  """
  use ConversationService.DataCase, async: false

  @moduletag :postgres_integration

  alias ConversationService.Conversations

  setup do
    prev = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)
    on_exit(fn -> Application.put_env(:conversation_service, :conversation_persistence, prev) end)
    :ok
  end

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

  defp user_without_external!(app_id) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', now(), now())",
      [id, app_id, "noext-#{id}@test.local"]
    )

    id
  end

  defp endpoint!(app_id) do
    Repo.query!(
      "INSERT INTO webhook_endpoints (id, app_id, url, signing_secret, event_types, enabled, created_at, updated_at) " <>
        "VALUES (gen_random_uuid(), $1::text::uuid, 'https://example.test/hook', 'secret', $2, true, now(), now())",
      [app_id, ["conversation.created"]]
    )
  end

  defp outbox(app_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT event_type, payload FROM webhook_outbox WHERE app_id = $1::text::uuid",
        [app_id]
      )

    Enum.map(rows, fn [event_type, payload] ->
      %{event_type: event_type, payload: decode(payload)}
    end)
  end

  defp decode(payload) when is_binary(payload), do: Jason.decode!(payload)
  defp decode(payload) when is_map(payload), do: payload

  defp create!(app_id, created_by, participants, extra \\ %{}) do
    Conversations.create_conversation(
      Map.merge(
        %{
          "type" => "group",
          "title" => "Webhook Test",
          "created_by" => created_by,
          "participant_user_ids" => participants,
          "app_id" => app_id
        },
        extra
      )
    )
  end

  test "creator + participants emit as EXTERNAL ids, batch-resolved; no internal user uuid in the JSON" do
    app = app!()
    endpoint!(app)
    a = user!(app, "alice_ext")
    b = user!(app, "bob_ext")
    c = user!(app, "carol_ext")

    assert {:ok, _} = create!(app, a, [b, c])

    assert [%{event_type: "conversation.created", payload: payload}] = outbox(app)
    assert payload["created_by_external_id"] == "alice_ext"
    # participant_user_ids includes the creator (the service adds them) — all external now.
    assert Enum.sort(payload["participant_external_ids"]) == ["alice_ext", "bob_ext", "carol_ext"]
    refute Map.has_key?(payload, "created_by")
    refute Map.has_key?(payload, "participant_user_ids")

    # No internal user uuid anywhere in the emitted JSON (the conversation_id stays a uuid — a resource id).
    json = Jason.encode!(payload)
    for internal <- [a, b, c], do: refute(json =~ internal)
    assert is_binary(payload["conversation_id"])
  end

  test "an unresolvable CREATOR drops the whole event (the create itself still succeeds)" do
    app = app!()
    endpoint!(app)
    creator = user_without_external!(app)
    b = user!(app, "bob_ext")

    assert {:ok, _} = create!(app, creator, [b])
    assert outbox(app) == []
  end

  test "an unresolvable PARTICIPANT is omitted; the event still emits with the rest" do
    app = app!()
    endpoint!(app)
    a = user!(app, "alice_ext")
    ghost = user_without_external!(app)
    b = user!(app, "bob_ext")

    assert {:ok, _} = create!(app, a, [ghost, b])

    assert [%{payload: payload}] = outbox(app)
    assert payload["created_by_external_id"] == "alice_ext"
    assert Enum.sort(payload["participant_external_ids"]) == ["alice_ext", "bob_ext"]
    refute Jason.encode!(payload) =~ ghost
  end
end

defmodule AuthService.AppUsageDeliveriesPostgresTest do
  @moduledoc """
  DB-backed proof of the owner-console SQL (the part a stub cannot prove):

    * `Apps.app_usage/1` counts MESSAGES via their PARENT CONVERSATION — the seed deliberately stamps the
      message's own `messages.app_id` with the OTHER app, so a count keyed on `messages.app_id` would
      return 0 and this test fails. The conversation is a message's authoritative tenant.
    * `Webhooks.list_deliveries/1` is scoped `WHERE app_id` — another app's outbox row is never returned,
      and `payload` (event body, incl. message content) / `signing_secret` are never selected.

  Tagged :postgres_integration — needs a real DB.
  """
  use ExUnit.Case, async: false

  alias AuthService.Apps
  alias AuthService.Repo
  alias AuthService.Webhooks

  setup do
    start_repo!()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  @tag :postgres_integration
  test "app_usage counts only the owned app, and counts messages via the PARENT conversation" do
    %{owned: owned, other: other} = seed_two_apps()

    # OWNED app: 1 user, 1 conversation, 1 message (whose messages.app_id says `other`!), 1024 bytes.
    assert {:ok, usage} = Apps.app_usage(%{"app_id" => owned})

    assert usage.app_id == owned
    assert usage.users == 1
    assert usage.conversations == 1

    # THE ASSERTION THAT MATTERS: the message's own app_id column points at `other`, but its parent
    # conversation belongs to `owned` — the join must count it. A `messages.app_id` count would give 0.
    assert usage.messages == 1
    assert usage.storage_bytes == 1024

    # The OTHER app's rows are never mixed in: it has its own conversation + message, and no media.
    assert {:ok, other_usage} = Apps.app_usage(%{"app_id" => other})
    assert other_usage.conversations == 1
    assert other_usage.storage_bytes == 0
  end

  @tag :postgres_integration
  test "list_deliveries returns ONLY the owned app's rows — another app's delivery is absent" do
    %{owned: owned, other: other, owned_outbox: owned_outbox, other_outbox: other_outbox} =
      seed_two_apps()

    assert {:ok, %{items: items}} = Webhooks.list_deliveries(%{"app_id" => owned})

    ids = Enum.map(items, & &1["id"])
    assert owned_outbox in ids
    refute other_outbox in ids

    row = Enum.find(items, &(&1["id"] == owned_outbox))
    assert row["event_type"] == "message.created"
    assert row["status"] == "failed"
    assert row["attempts"] == 2
    assert row["endpoint_url"] == "https://owned.example/hook"

    # Metadata only — never the event body (message content) nor the endpoint's signing secret.
    refute Map.has_key?(row, "payload")
    refute Map.has_key?(row, "signing_secret")

    # And the other app sees only ITS row.
    assert {:ok, %{items: other_items}} = Webhooks.list_deliveries(%{"app_id" => other})
    assert Enum.map(other_items, & &1["id"]) == [other_outbox]
  end

  @tag :postgres_integration
  test "list_deliveries refuses to run unscoped (no app_id → empty, never all apps' rows)" do
    seed_two_apps()
    assert {:ok, %{items: [], count: 0}} = Webhooks.list_deliveries(%{})
  end

  @tag :postgres_integration
  test "list_deliveries paginates on the (created_at, id) keyset" do
    %{owned: owned} = seed_two_apps()
    # A second delivery for the same app so there are 2 rows to page through.
    add_outbox!(owned, endpoint_for(owned), "conversation.created", "pending", 0)

    assert {:ok, %{items: [first], next_cursor: cursor}} =
             Webhooks.list_deliveries(%{"app_id" => owned, "limit" => 1})

    assert is_map(cursor)

    assert {:ok, %{items: [second]}} =
             Webhooks.list_deliveries(%{
               "app_id" => owned,
               "limit" => 1,
               "cursor_ts" => cursor["created_at"],
               "cursor_id" => cursor["id"]
             })

    # The cursor advanced — page 2 is a different row.
    refute first["id"] == second["id"]
  end

  # --- seed ------------------------------------------------------------------------------------------

  # Two apps. The OWNED app has: 1 user, 1 conversation, 1 message (stamped with the OTHER app's id on the
  # message row itself — see the test), 1 media asset (1024B), 1 endpoint + 1 failed outbox row.
  # The OTHER app has: 1 conversation + 1 message + 1 endpoint + 1 outbox row.
  defp seed_two_apps do
    owned = insert_app!("Owned")
    other = insert_app!("Other")

    user = insert_user!(owned)
    other_user = insert_user!(other)

    conv = insert_conversation!(owned, user)
    other_conv = insert_conversation!(other, other_user)

    # The message lives in the OWNED app's conversation, but its own app_id column says `other`.
    # Counting on messages.app_id would MISS it; the parent-conversation join must find it.
    insert_message!(conv, user, other)
    insert_message!(other_conv, other_user, other)

    insert_media!(owned, user, 1024)

    owned_ep = insert_endpoint!(owned, "https://owned.example/hook")
    other_ep = insert_endpoint!(other, "https://other.example/hook")

    owned_outbox = add_outbox!(owned, owned_ep, "message.created", "failed", 2)
    other_outbox = add_outbox!(other, other_ep, "message.created", "failed", 1)

    %{owned: owned, other: other, owned_outbox: owned_outbox, other_outbox: other_outbox}
  end

  defp uuid, do: Ecto.UUID.generate()
  defp uniq, do: System.unique_integer([:positive])

  defp insert_app!(name) do
    id = uuid()

    Repo.query!("INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, $2, $3)", [
      id,
      "#{name}-#{uniq()}",
      "#{String.downcase(name)}-#{uniq()}"
    ])

    id
  end

  defp insert_user!(app_id) do
    id = uuid()

    Repo.query!(
      "INSERT INTO users_auth (id, email, status, app_id) VALUES ($1::text::uuid, $2, 'active', $3::text::uuid)",
      [id, "u#{uniq()}@example.test", app_id]
    )

    id
  end

  defp insert_conversation!(app_id, created_by) do
    id = uuid()

    Repo.query!(
      "INSERT INTO conversations (id, type, created_by, status, app_id) " <>
        "VALUES ($1::text::uuid, 'group', $2::text::uuid, 'active', $3::text::uuid)",
      [id, created_by, app_id]
    )

    id
  end

  # `message_app_id` is stamped on the MESSAGE ROW — deliberately not the conversation's app.
  defp insert_message!(conversation_id, sender, message_app_id) do
    id = uuid()

    Repo.query!(
      "INSERT INTO messages (message_id, conversation_id, sender_user_id, message_type, body, status, app_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, 'text', 'hi', 'active', $4::text::uuid)",
      [id, conversation_id, sender, message_app_id]
    )

    id
  end

  defp insert_media!(app_id, owner, size) do
    id = uuid()

    Repo.query!(
      "INSERT INTO media_assets (id, owner_user_id, storage_provider, bucket, object_key, mime_type, " <>
        "size_bytes, status, app_id) VALUES ($1::text::uuid, $2::text::uuid, 'minio', 'media', $3, " <>
        "'image/png', $4, 'ready', $5::text::uuid)",
      [id, owner, "key-#{uniq()}", size, app_id]
    )

    id
  end

  defp insert_endpoint!(app_id, url) do
    id = uuid()

    Repo.query!(
      "INSERT INTO webhook_endpoints (id, app_id, url, signing_secret, enabled, event_types) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'whsec_test', true, ARRAY['message.created'])",
      [id, app_id, url]
    )

    id
  end

  defp endpoint_for(app_id) do
    %{rows: [[id]]} =
      Repo.query!(
        "SELECT id::text FROM webhook_endpoints WHERE app_id = $1::text::uuid LIMIT 1",
        [
          app_id
        ]
      )

    id
  end

  defp add_outbox!(app_id, endpoint_id, event_type, status, attempts) do
    id = uuid()

    Repo.query!(
      "INSERT INTO webhook_outbox (id, app_id, endpoint_id, event_id, event_type, payload, status, attempts) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4::text::uuid, $5, $6::jsonb, $7, $8)",
      [
        id,
        app_id,
        endpoint_id,
        uuid(),
        event_type,
        ~s({"secret_body":"never shown"}),
        status,
        attempts
      ]
    )

    id
  end

  defp start_repo! do
    case Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end

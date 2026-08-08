defmodule NotificationService.MessageStoreFixture do
  @moduledoc """
  Stands up the REAL message-store read path so notification_service's tests can exercise the push
  preview the way production does.

  NOTHING HERE IS A DOUBLE. It starts `MessageService.Repo`, pins the real
  `MessageService.MessageStore.PostgresAdapter`, runs the real `MessageService.HTTP.Router` on a
  local Cowboy listener, and points `SharedInfra.MessageClient` at the real
  `SharedInfra.MessageClientHttp` — the exact adapter the notification container uses once
  `MESSAGE_CLIENT_ADAPTER=http` is set. A hand-written stub returning a hand-written map is what two
  earlier slices were lost to; the shape has to come from the real store or it proves nothing.

  ## Why MessageService.Repo is NOT sandboxed

  `NotificationService.DataCase` wraps the notification side in a sandbox transaction on
  `NotificationService.Repo`. `MessageService.Repo` is a DIFFERENT pool, so a row written inside its
  own sandbox transaction is invisible to the notification connection — and `messages` has foreign
  keys to `users_auth` and `conversations`, which would then have to be seeded on BOTH connections,
  where the two uncommitted inserts of the same primary key deadlock.

  So this fixture COMMITS its rows and deletes them in `on_exit`. Both repos point at the same
  database, and a sandbox transaction reads rows committed before it, so the notification side sees
  them. The ids are per-test UUIDs, so a crashed run leaks a handful of rows rather than colliding.

  Available to notification_service's tests only because the umbrella test run puts every app on the
  code path. That is NOT true of the release, which carries `[shared_infra, notification_service]` —
  the exact gap `PushPreviewFailureTest` covers.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @port 4198
  @token "push-preview-fixture-token"
  @tenant_zero "00000000-0000-0000-0000-000000000001"

  @doc """
  Starts the store path and restores every application-env key it touched afterwards. Returns the
  base attrs a caller needs. Call from `setup`.
  """
  def start! do
    ensure_repo!()
    previous = capture_env()

    Application.put_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.PostgresAdapter
    )

    Application.put_env(:shared_infra, :internal_api_token, @token)
    Application.put_env(:shared_infra, :message_service_url, "http://localhost:#{@port}")
    Application.put_env(:shared_infra, :message_client_adapter, SharedInfra.MessageClientHttp)

    ExUnit.Callbacks.start_supervised!(
      {Plug.Cowboy, scheme: :http, plug: MessageService.HTTP.Router, options: [port: @port]}
    )

    on_exit(fn -> restore_env(previous) end)
    :ok
  end

  @doc """
  Inserts a real `messages` row (with the `users_auth` / `conversations` parents its foreign keys
  require) and registers deletion. `opts` may carry `:body`, `:message_type`, `:metadata` and
  `:deleted_at`.
  """
  def insert_message!(conversation_id, message_id, sender_user_id, opts \\ []) do
    repo = MessageService.Repo
    app_id = Keyword.get(opts, :app_id, @tenant_zero)

    repo.query!(
      "INSERT INTO users_auth (id, phone_number) VALUES ($1::text::uuid, $2) ON CONFLICT DO NOTHING",
      [sender_user_id, "+1555#{System.unique_integer([:positive])}"]
    )

    repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4::text::uuid) ON CONFLICT DO NOTHING",
      [conversation_id, app_id, Keyword.get(opts, :conversation_type, "group"), sender_user_id]
    )

    repo.query!(
      "INSERT INTO messages (message_id, conversation_id, app_id, sender_user_id, message_type, " <>
        "body, metadata, deleted_at) VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, " <>
        "$4::text::uuid, $5, $6, $7, $8)",
      [
        message_id,
        conversation_id,
        app_id,
        sender_user_id,
        Keyword.get(opts, :message_type, "text"),
        Keyword.get(opts, :body),
        # A MAP, not pre-encoded JSON: `metadata` is jsonb, and handing Postgrex a binary for a jsonb
        # param stores it as a JSON *string scalar*, which then fails to load as Ecto's :map type.
        Keyword.get(opts, :metadata, %{}),
        Keyword.get(opts, :deleted_at)
      ]
    )

    on_exit(fn ->
      repo.query!("DELETE FROM messages WHERE message_id = $1::text::uuid", [message_id])
      repo.query!("DELETE FROM conversations WHERE id = $1::text::uuid", [conversation_id])
      repo.query!("DELETE FROM users_auth WHERE id = $1::text::uuid", [sender_user_id])
    end)

    :ok
  end

  # Started UNLINKED and left running for the whole test run. Linked to the test process it would die
  # with the test, and `on_exit`'s cleanup DELETEs — which run after that — would find no repo.
  defp ensure_repo! do
    case MessageService.Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp capture_env do
    %{
      store: Application.get_env(:message_service, :message_store_adapter),
      token: Application.get_env(:shared_infra, :internal_api_token),
      url: Application.get_env(:shared_infra, :message_service_url),
      client: Application.get_env(:shared_infra, :message_client_adapter)
    }
  end

  defp restore_env(previous) do
    put = fn app, key, value ->
      if value, do: Application.put_env(app, key, value), else: Application.delete_env(app, key)
    end

    put.(:message_service, :message_store_adapter, previous.store)
    put.(:shared_infra, :internal_api_token, previous.token)
    put.(:shared_infra, :message_service_url, previous.url)
    put.(:shared_infra, :message_client_adapter, previous.client)
  end
end

defmodule MessageService.MessageStore do
  @moduledoc """
  Adapter boundary for message timeline persistence.

  The default adapter builds on existing ScyllaDB query-plan foundations but
  intentionally does not perform live network writes yet.
  """

  @type message_attrs :: map()
  @type message_result :: {:ok, map()} | {:error, atom()}
  @type timeline_result ::
          {:ok, %{conversation_id: String.t(), messages: list(), next_cursor: nil}}
          | {:error, atom()}

  @callback put_message(message_attrs()) :: message_result()
  @callback get_message(message_attrs()) :: message_result()
  @callback list_messages(message_attrs()) :: timeline_result()
  @callback update_message(message_attrs()) :: message_result()
  @callback delete_message(message_attrs()) :: message_result()
  @callback mark_delivered(message_attrs()) :: message_result()
  @callback mark_read(message_attrs()) :: message_result()
  @callback upsert_reaction(message_attrs()) :: message_result()
  @callback remove_reaction(message_attrs()) :: message_result()
  @callback star_message(message_attrs()) :: message_result()
  @callback unstar_message(message_attrs()) :: message_result()
  @callback list_starred(message_attrs()) :: timeline_result()
  @callback search_messages(message_attrs()) :: timeline_result()

  def put_message(attrs), do: adapter().put_message(attrs)
  def get_message(attrs), do: adapter().get_message(attrs)
  def list_messages(attrs), do: adapter().list_messages(attrs)
  def update_message(attrs), do: adapter().update_message(attrs)
  def delete_message(attrs), do: adapter().delete_message(attrs)
  def mark_delivered(attrs), do: adapter().mark_delivered(attrs)
  def mark_read(attrs), do: adapter().mark_read(attrs)
  def upsert_reaction(attrs), do: adapter().upsert_reaction(attrs)
  def remove_reaction(attrs), do: adapter().remove_reaction(attrs)
  def star_message(attrs), do: adapter().star_message(attrs)
  def unstar_message(attrs), do: adapter().unstar_message(attrs)
  def list_starred(attrs), do: adapter().list_starred(attrs)
  def search_messages(attrs), do: adapter().search_messages(attrs)

  defp adapter do
    Application.get_env(
      :message_service,
      :message_store_adapter,
      MessageService.MessageStore.QueryPlanAdapter
    )
  end
end

defmodule MessageService.MessageStore.QueryPlanAdapter do
  @moduledoc """
  Non-networked ScyllaDB store placeholder.

  This adapter exists so DB-backed service code has a clean persistence seam
  without pretending that live ScyllaDB execution is available.
  """

  @behaviour MessageService.MessageStore

  @impl true
  def put_message(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def get_message(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def list_messages(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def update_message(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def delete_message(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def mark_delivered(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def mark_read(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def upsert_reaction(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def remove_reaction(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def star_message(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def unstar_message(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def list_starred(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def search_messages(_attrs), do: {:error, :message_store_unavailable}
end

defmodule MessageService.MessageStore.ScyllaAdapter do
  @moduledoc """
  ScyllaDB adapter backed by the configured `SharedInfra.Scylla.Client`.

  This adapter is not the default yet. Configure `:scylla_client_adapter` with a
  real client module before enabling it in an environment.
  """

  @behaviour MessageService.MessageStore

  alias MessageService.Persistence.MessageTimelineReads
  alias MessageService.Persistence.MessageTimelineWrites
  alias MessageService.Persistence.MessageReceipts

  @impl true
  def put_message(attrs) do
    plan = MessageTimelineWrites.insert_message_plan(attrs)

    with {:ok, client} <- client_adapter(),
         {:ok, _result} <- execute(client, plan) do
      {:ok, message_response(attrs)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_message(attrs) do
    message_id = attr(attrs, "message_id")
    plan = MessageTimelineReads.list_recent_plan(Map.put_new(attrs, "limit", 200))

    with {:ok, client} <- client_adapter(),
         {:ok, result} <- execute(client, plan) do
      result
      |> rows()
      |> Enum.find(fn row -> attr(row, "message_id") == message_id end)
      |> case do
        nil -> {:error, :message_not_found}
        row -> {:ok, message_response(row)}
      end
    end
  end

  @impl true
  def list_messages(attrs) do
    plan = MessageTimelineReads.list_recent_plan(attrs)

    with {:ok, client} <- client_adapter(),
         {:ok, result} <- execute(client, plan) do
      {:ok,
       %{
         conversation_id: attrs["conversation_id"],
         messages: result |> rows() |> Enum.map(&message_response/1),
         next_cursor: nil
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update_message(attrs) do
    plan = MessageTimelineWrites.mark_edited_plan(attrs)

    with {:ok, client} <- client_adapter(),
         {:ok, _result} <- execute(client, plan) do
      {:ok, message_response(Map.merge(attrs, %{"status" => "edited"}))}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_message(attrs) do
    plan = MessageTimelineWrites.mark_deleted_plan(attrs)

    with {:ok, client} <- client_adapter(),
         {:ok, _result} <- execute(client, plan) do
      {:ok, message_response(Map.merge(attrs, %{"status" => "deleted"}))}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def mark_delivered(attrs) do
    put_receipt(Map.merge(attrs, %{"status" => "delivered"}))
  end

  @impl true
  def mark_read(attrs) do
    put_receipt(Map.merge(attrs, %{"status" => "read"}))
  end

  # Reactions/stars/search aren't implemented for the Scylla store yet — Postgres is the durable backend.
  @impl true
  def upsert_reaction(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def remove_reaction(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def star_message(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def unstar_message(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def list_starred(_attrs), do: {:error, :message_store_unavailable}

  @impl true
  def search_messages(_attrs), do: {:error, :message_store_unavailable}

  defp put_receipt(attrs) do
    plan = MessageReceipts.upsert_receipt_plan(attrs)

    with {:ok, client} <- client_adapter(),
         {:ok, _result} <- execute(client, plan) do
      {:ok, receipt_response(attrs)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp client_adapter do
    case Application.get_env(:message_service, :scylla_client_adapter, SharedInfra.Scylla.Client) do
      adapter when is_atom(adapter) -> {:ok, adapter}
      _ -> {:error, :message_store_unavailable}
    end
  end

  defp execute(client, plan) do
    case client.execute(plan.statement, plan.params, scylla_config()) do
      {:error, :scylla_unavailable} -> {:error, :message_store_unavailable}
      result -> result
    end
  end

  defp scylla_config do
    MessageService.Infrastructure.scylla_config()
  end

  defp rows(%{rows: rows}) when is_list(rows), do: rows
  defp rows(%{"rows" => rows}) when is_list(rows), do: rows
  defp rows(rows) when is_list(rows), do: rows
  defp rows(_result), do: []

  defp message_response(attrs) do
    %{
      conversation_id: attr(attrs, "conversation_id"),
      bucket_date: attr(attrs, "bucket_date"),
      message_id: attr(attrs, "message_id"),
      sender_user_id: attr(attrs, "sender_user_id"),
      message_type: attr(attrs, "message_type"),
      body: attr(attrs, "body"),
      media_id: attr(attrs, "media_id"),
      reply_to_message_id: attr(attrs, "reply_to_message_id"),
      status: attr(attrs, "status"),
      metadata: attr(attrs, "metadata") || %{},
      created_at: attr(attrs, "created_at"),
      edited_at: attr(attrs, "edited_at"),
      deleted_at: attr(attrs, "deleted_at")
    }
  end

  defp receipt_response(attrs) do
    %{
      conversation_id: attr(attrs, "conversation_id"),
      message_id: attr(attrs, "message_id"),
      user_id: attr(attrs, "user_id"),
      status: attr(attrs, "status"),
      updated_at: attr(attrs, "updated_at")
    }
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end
end

defmodule MessageService.MessageStore.InMemoryAdapter do
  @moduledoc """
  Test-safe in-memory message store adapter.
  """

  @behaviour MessageService.MessageStore

  use Agent

  @name __MODULE__

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> initial_state() end, name: @name)
  end

  def reset do
    ensure_started()
    Agent.update(@name, fn _state -> initial_state() end)
  end

  @doc """
  Test helper: seed conversation membership so `search_messages` scoping (a user only searches their
  own conversations) is exercisable Docker-free. Postgres scopes via the real `conversation_participants`
  table; the in-memory store carries its own minimal participant set.
  """
  def seed_participant(conversation_id, user_id) do
    ensure_started()

    Agent.update(@name, fn state ->
      participant = %{conversation_id: conversation_id, user_id: user_id}
      %{state | participants: [participant | state.participants]}
    end)
  end

  @impl true
  def put_message(attrs) do
    ensure_started()
    message = message_response(attrs)

    Agent.update(@name, fn state -> %{state | messages: [message | state.messages]} end)

    {:ok, message}
  end

  @impl true
  def get_message(attrs) do
    ensure_started()

    case find_message(attrs) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message}
    end
  end

  @impl true
  def list_messages(attrs) do
    ensure_started()

    conversation_id = Map.fetch!(attrs, "conversation_id")
    bucket_date = Map.fetch!(attrs, "bucket_date")
    limit = Map.get(attrs, "limit", 50)
    viewer = Map.get(attrs, "viewer_user_id")

    {all_messages, receipts, reactions, stars} =
      Agent.get(@name, fn state ->
        {state.messages, state.receipts, state.reactions, state.stars}
      end)

    messages =
      all_messages
      |> Enum.filter(&(&1.conversation_id == conversation_id and &1.bucket_date == bucket_date))
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
      |> Enum.take(limit)
      |> Enum.map(fn message ->
        message
        |> Map.drop([:bucket_date])
        |> Map.merge(receipt_counts(receipts, message.message_id))
        |> Map.merge(reaction_summary(reactions, message.message_id, viewer))
        |> Map.put(:is_starred, starred?(stars, message.message_id, viewer))
      end)

    {:ok, %{conversation_id: conversation_id, messages: messages, next_cursor: nil}}
  end

  # Whether `viewer` has starred this message (drives the filled star on load).
  defp starred?(_stars, _message_id, nil), do: false

  defp starred?(stars, message_id, viewer) do
    Enum.any?(stars, &(&1.message_id == message_id and &1.user_id == viewer))
  end

  # Per-message reaction aggregate: emoji → count (desc), plus the viewer's own emoji (or nil).
  defp reaction_summary(reactions, message_id, viewer) do
    for_message = Enum.filter(reactions, &(&1.message_id == message_id))

    summary =
      for_message
      |> Enum.frequencies_by(& &1.emoji)
      |> Enum.map(fn {emoji, count} -> %{emoji: emoji, count: count} end)
      |> Enum.sort_by(fn %{count: c, emoji: e} -> {-c, e} end)

    my =
      Enum.find_value(for_message, nil, fn r -> if r.user_id == viewer, do: r.emoji end)

    %{reactions: summary, my_reaction: my}
  end

  # Per-message read/delivered aggregate (others who have read/received it). Each receipt row is a
  # distinct user (conversation+message+user is unique), so a simple count over non-nil timestamps
  # gives the per-message totals the timeline surfaces to the client.
  defp receipt_counts(receipts, message_id) do
    for_message = Enum.filter(receipts, &(&1.message_id == message_id))

    %{
      read_by_count: Enum.count(for_message, &(&1[:read_at] != nil)),
      delivered_by_count: Enum.count(for_message, &(&1[:delivered_at] != nil))
    }
  end

  @impl true
  def update_message(attrs) do
    ensure_started()

    updated_message =
      attrs
      |> find_message()
      |> case do
        nil ->
          nil

        message ->
          message
          |> Map.put(:body, attrs["body"])
          |> Map.put(:status, "edited")
          |> Map.put(:edited_at, attrs["edited_at"])
      end

    case updated_message do
      nil ->
        {:error, :message_not_found}

      message ->
        replace_message(message)
        {:ok, message}
    end
  end

  @impl true
  def mark_delivered(attrs) do
    ensure_started()
    receipt = upsert_receipt(attrs, "delivered", attrs["updated_at"])
    {:ok, receipt}
  end

  @impl true
  def mark_read(attrs) do
    ensure_started()
    receipt = upsert_receipt(attrs, "read", attrs["updated_at"])
    {:ok, receipt}
  end

  @impl true
  def upsert_reaction(attrs) do
    ensure_started()
    message_id = attrs["message_id"]
    user_id = attrs["user_id"]

    Agent.update(@name, fn state ->
      others =
        Enum.reject(state.reactions, &(&1.message_id == message_id and &1.user_id == user_id))

      reaction = %{
        conversation_id: attrs["conversation_id"],
        message_id: message_id,
        user_id: user_id,
        emoji: attrs["emoji"]
      }

      %{state | reactions: [reaction | others]}
    end)

    {:ok, %{message_id: message_id, reactions: reactions_for(message_id)}}
  end

  @impl true
  def remove_reaction(attrs) do
    ensure_started()
    message_id = attrs["message_id"]
    user_id = attrs["user_id"]

    Agent.update(@name, fn state ->
      %{
        state
        | reactions:
            Enum.reject(state.reactions, &(&1.message_id == message_id and &1.user_id == user_id))
      }
    end)

    {:ok, %{message_id: message_id, reactions: reactions_for(message_id)}}
  end

  defp reactions_for(message_id) do
    @name
    |> Agent.get(& &1.reactions)
    |> Enum.filter(&(&1.message_id == message_id))
    |> Enum.frequencies_by(& &1.emoji)
    |> Enum.map(fn {emoji, count} -> %{emoji: emoji, count: count} end)
    |> Enum.sort_by(fn %{count: c, emoji: e} -> {-c, e} end)
  end

  @impl true
  def star_message(attrs) do
    ensure_started()
    user_id = attrs["user_id"]
    message_id = attrs["message_id"]

    Agent.update(@name, fn state ->
      already = Enum.any?(state.stars, &(&1.message_id == message_id and &1.user_id == user_id))

      if already do
        state
      else
        star = %{
          user_id: user_id,
          message_id: message_id,
          conversation_id: attrs["conversation_id"],
          created_at: attrs["created_at"] || DateTime.utc_now()
        }

        %{state | stars: [star | state.stars]}
      end
    end)

    {:ok, %{message_id: message_id, is_starred: true}}
  end

  @impl true
  def unstar_message(attrs) do
    ensure_started()
    user_id = attrs["user_id"]
    message_id = attrs["message_id"]

    Agent.update(@name, fn state ->
      %{
        state
        | stars:
            Enum.reject(state.stars, &(&1.message_id == message_id and &1.user_id == user_id))
      }
    end)

    {:ok, %{message_id: message_id, is_starred: false}}
  end

  @impl true
  def list_starred(attrs) do
    ensure_started()
    user_id = attrs["user_id"]
    {limit, offset} = page_window(attrs)

    {messages, stars} = Agent.get(@name, fn state -> {state.messages, state.stars} end)
    by_id = Map.new(messages, &{&1.message_id, &1})

    starred =
      stars
      |> Enum.filter(&(&1.user_id == user_id))
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(fn star -> by_id[star.message_id] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn message ->
        message
        |> Map.drop([:bucket_date])
        |> Map.put(:is_starred, true)
      end)

    {:ok, %{messages: starred, next_cursor: nil}}
  end

  @impl true
  def search_messages(attrs) do
    ensure_started()
    user_id = attrs["user_id"]
    query = String.downcase(attrs["query"] || "")
    {limit, offset} = page_window(attrs)

    {messages, participants} =
      Agent.get(@name, fn state -> {state.messages, state.participants} end)

    my_conversations =
      participants
      |> Enum.filter(&(&1.user_id == user_id))
      |> MapSet.new(& &1.conversation_id)

    matches =
      messages
      |> Enum.filter(fn message ->
        message.status != "deleted" and
          MapSet.member?(my_conversations, message.conversation_id) and
          is_binary(message.body) and String.contains?(String.downcase(message.body), query)
      end)
      |> Enum.sort_by(& &1.created_at, {:desc, DateTime})
      |> Enum.drop(offset)
      |> Enum.take(limit)
      |> Enum.map(&Map.drop(&1, [:bucket_date]))

    {:ok, %{messages: matches, next_cursor: nil}}
  end

  # (limit, offset) from a 1-based page param (default page 1, 50/page).
  defp page_window(attrs) do
    page = max(attrs["page"] || 1, 1)
    limit = attrs["limit"] || 50
    {limit, (page - 1) * limit}
  end

  @impl true
  def delete_message(attrs) do
    ensure_started()

    deleted_message =
      attrs
      |> find_message()
      |> case do
        nil ->
          nil

        message ->
          message
          |> Map.put(:status, "deleted")
          |> Map.put(:deleted_at, attrs["deleted_at"])
      end

    case deleted_message do
      nil ->
        {:error, :message_not_found}

      message ->
        replace_message(message)
        {:ok, message}
    end
  end

  defp message_response(attrs) do
    %{
      conversation_id: attrs["conversation_id"],
      bucket_date: attrs["bucket_date"],
      message_id: attrs["message_id"],
      sender_user_id: attrs["sender_user_id"],
      message_type: attrs["message_type"],
      body: attrs["body"],
      media_id: attrs["media_id"],
      reply_to_message_id: attrs["reply_to_message_id"],
      status: attrs["status"],
      metadata: attrs["metadata"],
      created_at: attrs["created_at"],
      edited_at: attrs["edited_at"],
      deleted_at: attrs["deleted_at"]
    }
  end

  defp find_message(attrs) do
    conversation_id = Map.fetch!(attrs, "conversation_id")
    bucket_date = Map.fetch!(attrs, "bucket_date")
    message_id = Map.fetch!(attrs, "message_id")

    Agent.get(@name, fn state ->
      Enum.find(
        state.messages,
        &(&1.conversation_id == conversation_id and &1.bucket_date == bucket_date and
            &1.message_id == message_id)
      )
    end)
  end

  defp replace_message(message) do
    Agent.update(@name, fn state ->
      messages =
        Enum.map(state.messages, fn existing ->
          if existing.conversation_id == message.conversation_id and
               existing.bucket_date == message.bucket_date and
               existing.message_id == message.message_id do
            message
          else
            existing
          end
        end)

      %{state | messages: messages}
    end)
  end

  defp upsert_receipt(attrs, status, timestamp) do
    Agent.get_and_update(@name, fn state ->
      receipt =
        state.receipts
        |> Enum.find(&same_receipt?(&1, attrs))
        |> receipt_response(attrs, status, timestamp)

      receipts = [receipt | Enum.reject(state.receipts, &same_receipt?(&1, attrs))]

      {receipt, %{state | receipts: receipts}}
    end)
  end

  defp same_receipt?(receipt, attrs) do
    receipt.conversation_id == attrs["conversation_id"] and
      receipt.message_id == attrs["message_id"] and receipt.user_id == attrs["user_id"]
  end

  defp receipt_response(nil, attrs, "delivered", timestamp) do
    %{
      conversation_id: attrs["conversation_id"],
      message_id: attrs["message_id"],
      user_id: attrs["user_id"],
      status: "delivered",
      delivered_at: timestamp,
      read_at: nil,
      updated_at: timestamp
    }
  end

  defp receipt_response(nil, attrs, "read", timestamp) do
    %{
      conversation_id: attrs["conversation_id"],
      message_id: attrs["message_id"],
      user_id: attrs["user_id"],
      status: "read",
      delivered_at: nil,
      read_at: timestamp,
      updated_at: timestamp
    }
  end

  defp receipt_response(receipt, _attrs, "delivered", timestamp) do
    receipt
    |> Map.put(:status, "delivered")
    |> Map.put(:delivered_at, timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp receipt_response(receipt, _attrs, "read", timestamp) do
    receipt
    |> Map.put(:status, "read")
    |> Map.put(:read_at, timestamp)
    |> Map.put(:updated_at, timestamp)
  end

  defp initial_state,
    do: %{messages: [], receipts: [], reactions: [], stars: [], participants: []}

  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        {:ok, _pid} = Agent.start_link(fn -> initial_state() end, name: @name)
        :ok

      _pid ->
        :ok
    end
  end
end

defmodule MessageService.MessageStore.PostgresAdapter do
  @moduledoc """
  Postgres-backed message store adapter (durability backend).

  Selected via `MESSAGE_STORE_ADAPTER=postgres`. Returns the same atom-keyed
  response shapes as the other adapters so the layers above the store boundary
  (authz, response building) are unchanged. Lookups are by `message_id` /
  `conversation_id` only — there are no Scylla partitions, so the cross-day
  `bucket_date` limitation does not apply here.
  """

  @behaviour MessageService.MessageStore

  import Ecto.Query

  alias MessageService.Repo
  alias MessageService.Schemas.Message
  alias MessageService.Schemas.MessageReaction
  alias MessageService.Schemas.MessageReceipt
  alias MessageService.Schemas.StarredMessage

  @impl true
  def put_message(attrs) do
    # TRANSACTIONAL OUTBOX: the message insert AND its webhook_outbox rows commit (or roll back) as ONE
    # Postgres transaction via the SAME Repo — so a rolled-back message produces no webhook, and a
    # committed message guarantees its outbox rows (no lost-event window). The outbox is scoped to the
    # message's AUTHORITATIVE app_id (its conversation's app_id — same authority as the /v1 isolation
    # gate), looked up inside the transaction.
    Repo.transaction(fn ->
      # Resolve the conversation's AUTHORITATIVE app_id up-front and STAMP it on the message row
      # (put_change, so a caller-supplied app_id can't spoof it) — messages.app_id is now trustworthy,
      # not the tenant-zero default, and always agrees with the emitted event's app_id. An unknown
      # conversation resolves to nil → reject (no orphan message under the wrong tenant). The
      # conversation gate remains the enforcing authority; this is defense-in-depth.
      case conversation_app_id(message_conversation_id(attrs)) do
        nil ->
          Repo.rollback(:message_invalid)

        app_id ->
          changeset =
            %Message{}
            |> Message.changeset(attrs)
            |> Ecto.Changeset.put_change(:app_id, app_id)

          case Repo.insert(changeset) do
            {:ok, message} ->
              SharedInfra.WebhookOutbox.emit(Repo, app_id, "message.created", message_event(message))
              message_response(message)

            {:error, _changeset} ->
              Repo.rollback(:message_invalid)
          end
      end
    end)
    |> case do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  # The message's authoritative tenant = its conversation's app_id (read inside the same transaction).
  # nil conversation_id or unknown conversation → nil (caller rejects the insert).
  defp conversation_app_id(conversation_id)
       when is_binary(conversation_id) and conversation_id != "" do
    case Repo.query("SELECT app_id::text FROM conversations WHERE id = $1::text::uuid", [
           conversation_id
         ]) do
      {:ok, %{rows: [[app_id]]}} -> app_id
      _ -> nil
    end
  end

  defp conversation_app_id(_), do: nil

  # conversation_id from the insert attrs (string or atom keyed), read BEFORE the row exists.
  defp message_conversation_id(attrs),
    do: Map.get(attrs, "conversation_id") || Map.get(attrs, :conversation_id)

  # The `data` body an integrator receives for message.created (the worker wraps it in the signed envelope).
  defp message_event(%Message{} = message) do
    %{
      "message_id" => message.message_id,
      "conversation_id" => message.conversation_id,
      "sender_user_id" => message.sender_user_id,
      "message_type" => message.message_type,
      "body" => message.body,
      "created_at" => to_iso(message.created_at)
    }
  end

  defp to_iso(nil), do: nil
  defp to_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp to_iso(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp to_iso(other), do: other

  @impl true
  def get_message(attrs) do
    case fetch(attrs) do
      nil -> {:error, :message_not_found}
      message -> {:ok, message_response(message)}
    end
  end

  @impl true
  def list_messages(attrs) do
    conversation_id = attr(attrs, "conversation_id")
    limit = attr(attrs, "limit") || 50
    viewer = attr(attrs, "viewer_user_id")

    rows =
      Message
      |> where([m], m.conversation_id == ^conversation_id)
      |> order_by([m], desc: m.created_at)
      |> limit(^limit)
      |> Repo.all()

    message_ids = Enum.map(rows, & &1.message_id)
    counts = receipt_counts(conversation_id, message_ids)
    reactions = reaction_summaries(message_ids, viewer)
    starred = starred_set(message_ids, viewer)

    messages =
      Enum.map(rows, fn message ->
        message
        |> message_response()
        |> Map.merge(
          Map.get(counts, message.message_id, %{read_by_count: 0, delivered_by_count: 0})
        )
        |> Map.merge(Map.get(reactions, message.message_id, %{reactions: [], my_reaction: nil}))
        |> Map.put(:is_starred, MapSet.member?(starred, message.message_id))
      end)

    {:ok, %{conversation_id: conversation_id, messages: messages, next_cursor: nil}}
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  # The subset of the listed message_ids that `viewer` has starred (one query, no N+1).
  defp starred_set(_message_ids, nil), do: MapSet.new()
  defp starred_set([], _viewer), do: MapSet.new()

  defp starred_set(message_ids, viewer) do
    StarredMessage
    |> where([s], s.user_id == ^viewer and s.message_id in ^message_ids)
    |> select([s], s.message_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # Batched reaction aggregate for the listed messages: emoji → count per message (one query) + the
  # viewer's own reaction per message (one query). No N+1.
  defp reaction_summaries([], _viewer), do: %{}

  defp reaction_summaries(message_ids, viewer) do
    counts =
      MessageReaction
      |> where([r], r.message_id in ^message_ids)
      |> group_by([r], [r.message_id, r.emoji])
      |> select([r], {r.message_id, r.emoji, count(r.user_id)})
      |> Repo.all()
      |> Enum.group_by(fn {mid, _e, _c} -> mid end, fn {_mid, e, c} -> %{emoji: e, count: c} end)
      |> Map.new(fn {mid, list} ->
        {mid, Enum.sort_by(list, fn %{count: c, emoji: e} -> {-c, e} end)}
      end)

    mine =
      if viewer do
        MessageReaction
        |> where([r], r.message_id in ^message_ids and r.user_id == ^viewer)
        |> select([r], {r.message_id, r.emoji})
        |> Repo.all()
        |> Map.new()
      else
        %{}
      end

    Map.new(message_ids, fn mid ->
      {mid, %{reactions: Map.get(counts, mid, []), my_reaction: Map.get(mine, mid)}}
    end)
  end

  # Batched read/delivered aggregate for the listed messages in ONE query (no N+1). COUNT(column)
  # ignores NULLs, and each (conversation, message, user) receipt row is a distinct user, so the count
  # is the number of other users who have read / received each message.
  defp receipt_counts(_conversation_id, []), do: %{}

  defp receipt_counts(conversation_id, message_ids) do
    MessageReceipt
    |> where([r], r.conversation_id == ^conversation_id and r.message_id in ^message_ids)
    |> group_by([r], r.message_id)
    |> select([r], {r.message_id, count(r.read_at), count(r.delivered_at)})
    |> Repo.all()
    |> Map.new(fn {message_id, read_by, delivered_by} ->
      {message_id, %{read_by_count: read_by, delivered_by_count: delivered_by}}
    end)
  end

  @impl true
  def update_message(attrs) do
    case fetch(attrs) do
      nil ->
        {:error, :message_not_found}

      message ->
        message
        |> Message.changeset(%{
          "body" => attr(attrs, "body"),
          "status" => "edited",
          "edited_at" => attr(attrs, "edited_at")
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, message_response(updated)}
          {:error, _changeset} -> {:error, :message_invalid}
        end
    end
  end

  @impl true
  def delete_message(attrs) do
    case fetch(attrs) do
      nil ->
        {:error, :message_not_found}

      message ->
        message
        |> Message.changeset(%{
          "status" => "deleted",
          "deleted_at" => attr(attrs, "deleted_at")
        })
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, message_response(updated)}
          {:error, _changeset} -> {:error, :message_invalid}
        end
    end
  end

  @impl true
  def mark_delivered(attrs), do: upsert_receipt(attrs, "delivered")

  @impl true
  def mark_read(attrs), do: upsert_receipt(attrs, "read")

  @impl true
  def upsert_reaction(attrs) do
    now = DateTime.utc_now()
    message_id = attr(attrs, "message_id")
    emoji = attr(attrs, "emoji")

    %MessageReaction{}
    |> MessageReaction.changeset(%{
      "conversation_id" => attr(attrs, "conversation_id"),
      "message_id" => message_id,
      "user_id" => attr(attrs, "user_id"),
      "emoji" => emoji,
      "created_at" => now,
      "updated_at" => now
    })
    |> Repo.insert(
      on_conflict: [set: [emoji: emoji, updated_at: now]],
      conflict_target: [:message_id, :user_id]
    )
    |> case do
      {:ok, _reaction} -> {:ok, %{message_id: message_id, reactions: reactions_for(message_id)}}
      {:error, _changeset} -> {:error, :message_invalid}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  @impl true
  def remove_reaction(attrs) do
    message_id = attr(attrs, "message_id")
    user_id = attr(attrs, "user_id")

    MessageReaction
    |> where([r], r.message_id == ^message_id and r.user_id == ^user_id)
    |> Repo.delete_all()

    {:ok, %{message_id: message_id, reactions: reactions_for(message_id)}}
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  defp reactions_for(message_id) do
    MessageReaction
    |> where([r], r.message_id == ^message_id)
    |> group_by([r], r.emoji)
    |> select([r], {r.emoji, count(r.user_id)})
    |> Repo.all()
    |> Enum.map(fn {emoji, count} -> %{emoji: emoji, count: count} end)
    |> Enum.sort_by(fn %{count: c, emoji: e} -> {-c, e} end)
  end

  @impl true
  def star_message(attrs) do
    message_id = attr(attrs, "message_id")

    %StarredMessage{}
    |> StarredMessage.changeset(%{
      "user_id" => attr(attrs, "user_id"),
      "message_id" => message_id,
      "conversation_id" => attr(attrs, "conversation_id"),
      "created_at" => DateTime.utc_now()
    })
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:user_id, :message_id])
    |> case do
      {:ok, _star} -> {:ok, %{message_id: message_id, is_starred: true}}
      {:error, _changeset} -> {:error, :message_invalid}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  @impl true
  def unstar_message(attrs) do
    user_id = attr(attrs, "user_id")
    message_id = attr(attrs, "message_id")

    StarredMessage
    |> where([s], s.user_id == ^user_id and s.message_id == ^message_id)
    |> Repo.delete_all()

    {:ok, %{message_id: message_id, is_starred: false}}
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  @impl true
  def list_starred(attrs) do
    user_id = attr(attrs, "user_id")
    {limit, offset} = page_window(attrs)

    rows =
      StarredMessage
      |> join(:inner, [s], m in Message, on: m.message_id == s.message_id)
      |> where([s], s.user_id == ^user_id)
      |> order_by([s], desc: s.created_at)
      |> limit(^limit)
      |> offset(^offset)
      |> select([_s, m], m)
      |> Repo.all()

    {:ok,
     %{
       messages: Enum.map(rows, &Map.put(message_response(&1), :is_starred, true)),
       next_cursor: nil
     }}
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  @impl true
  def search_messages(attrs) do
    user_id = attr(attrs, "user_id")
    pattern = "%" <> escape_like(attr(attrs, "query") || "") <> "%"
    {limit, offset} = page_window(attrs)

    # Privacy scoping: only messages in conversations the caller still participates in (left_at IS NULL).
    # NOTE: a leading-% ILIKE can't use a btree index → sequential scan; fine at this scale. The scale
    # upgrade is a pg_trgm GIN index on messages.body (intentionally NOT added now).
    rows =
      Message
      |> join(:inner, [m], p in "conversation_participants",
        on: p.conversation_id == m.conversation_id
      )
      # `conversation_participants` is a schemaless source here, so Ecto can't infer the column type —
      # cast the bound user_id to :binary_id explicitly (else Postgrex rejects the raw uuid string).
      |> where([m, p], p.user_id == type(^user_id, :binary_id) and is_nil(p.left_at))
      |> where([m], m.status != "deleted")
      |> where([m], ilike(m.body, ^pattern))
      |> order_by([m], desc: m.created_at)
      |> limit(^limit)
      |> offset(^offset)
      |> select([m], m)
      |> Repo.all()

    {:ok, %{messages: Enum.map(rows, &message_response/1), next_cursor: nil}}
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  # Escape LIKE/ILIKE metacharacters so a user's query is matched literally (default backslash escape).
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  # (limit, offset) from a 1-based page param (default page 1, 50/page).
  defp page_window(attrs) do
    page = max(attr(attrs, "page") || 1, 1)
    limit = attr(attrs, "limit") || 50
    {limit, (page - 1) * limit}
  end

  defp fetch(attrs) do
    Repo.get(Message, attr(attrs, "message_id"))
  rescue
    Ecto.Query.CastError -> nil
  end

  defp upsert_receipt(attrs, status) do
    conversation_id = attr(attrs, "conversation_id")
    message_id = attr(attrs, "message_id")
    user_id = attr(attrs, "user_id")
    timestamp = attr(attrs, "updated_at")

    existing =
      Repo.get_by(MessageReceipt,
        conversation_id: conversation_id,
        message_id: message_id,
        user_id: user_id
      )

    base = existing || %MessageReceipt{}

    changes =
      %{
        "conversation_id" => conversation_id,
        "message_id" => message_id,
        "user_id" => user_id,
        "status" => status,
        "updated_at" => timestamp
      }
      |> Map.put(timestamp_field(status), timestamp)

    base
    |> MessageReceipt.changeset(changes)
    |> Repo.insert_or_update()
    |> case do
      {:ok, receipt} -> {:ok, receipt_response(receipt)}
      {:error, _changeset} -> {:error, :message_invalid}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  defp timestamp_field("delivered"), do: "delivered_at"
  defp timestamp_field("read"), do: "read_at"

  defp message_response(%Message{} = message) do
    %{
      conversation_id: message.conversation_id,
      message_id: message.message_id,
      sender_user_id: message.sender_user_id,
      message_type: message.message_type,
      body: message.body,
      media_id: message.media_id,
      reply_to_message_id: message.reply_to_message_id,
      status: message.status,
      metadata: message.metadata,
      created_at: message.created_at,
      edited_at: message.edited_at,
      deleted_at: message.deleted_at
    }
  end

  defp receipt_response(%MessageReceipt{} = receipt) do
    %{
      conversation_id: receipt.conversation_id,
      message_id: receipt.message_id,
      user_id: receipt.user_id,
      status: receipt.status,
      delivered_at: receipt.delivered_at,
      read_at: receipt.read_at,
      updated_at: receipt.updated_at
    }
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
end

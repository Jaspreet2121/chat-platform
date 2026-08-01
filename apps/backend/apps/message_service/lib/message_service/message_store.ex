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
  @callback list_media(message_attrs()) :: timeline_result()
  @callback get_by_media_id(message_attrs()) :: message_result()
  # Message info (per-user delivery/read state; sender-only) — optional, Postgres + InMemory implement it.
  @callback message_info(message_attrs()) :: message_result()
  # Polls — replace-the-set vote + the uncapped voter lists (optional; Postgres + InMemory).
  @callback poll_vote(message_attrs()) :: message_result()
  @callback list_poll_votes(message_attrs()) :: message_result()
  # Owner-anchored media-download authorization (optional; Postgres only).
  @callback media_download_allowed(message_attrs()) :: message_result()
  @optional_callbacks list_media: 1,
                      get_by_media_id: 1,
                      message_info: 1,
                      poll_vote: 1,
                      list_poll_votes: 1,
                      media_download_allowed: 1

  def put_message(attrs), do: adapter().put_message(attrs)
  def get_message(attrs), do: adapter().get_message(attrs)
  def list_messages(attrs), do: adapter().list_messages(attrs)

  # Shared-media gallery (optional callback — only the Postgres adapter implements it).
  def list_media(attrs) do
    store = adapter()

    if function_exported?(store, :list_media, 1) do
      store.list_media(attrs)
    else
      {:error, :message_unavailable}
    end
  end

  # Media-authorization support: the conversation a media_id was sent to (optional callback — Postgres
  # only). Returns {:ok, %{conversation_id}} or {:error, :not_found} for an unsent/unknown media_id.
  def get_by_media_id(attrs) do
    store = adapter()

    if function_exported?(store, :get_by_media_id, 1) do
      store.get_by_media_id(attrs)
    else
      {:error, :message_unavailable}
    end
  end

  # The OWNER-ANCHORED download rule (optional callback — Postgres only): is the viewer an active member
  # of ANY conversation containing a message referencing this media_id whose SENDER is the asset's owner?
  def media_download_allowed(attrs) do
    store = adapter()

    if function_exported?(store, :media_download_allowed, 1) do
      store.media_download_allowed(attrs)
    else
      {:error, :message_unavailable}
    end
  end

  # Message info — WHO has received/read a message, per user (optional callback; Postgres + InMemory).
  def message_info(attrs) do
    store = adapter()

    if function_exported?(store, :message_info, 1) do
      store.message_info(attrs)
    else
      {:error, :message_unavailable}
    end
  end

  # Polls (optional callbacks; Postgres + InMemory).
  def poll_vote(attrs) do
    store = adapter()

    if function_exported?(store, :poll_vote, 1) do
      store.poll_vote(attrs)
    else
      {:error, :message_unavailable}
    end
  end

  def list_poll_votes(attrs) do
    store = adapter()

    if function_exported?(store, :list_poll_votes, 1) do
      store.list_poll_votes(attrs)
    else
      {:error, :message_unavailable}
    end
  end

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
  ScyllaDB adapter backed by the configured `SharedInfra.Scylla.Client`. NOT the default; selecting it
  requires `MESSAGE_STORE_ADAPTER=scylla` plus a configured client — production is Postgres.

  Every export is one of exactly TWO things — verified against a REAL Scylla in CI
  (`scripts/test-scylla.sh`, `@tag :scylla_integration`), or an explicit documented stub. There is no
  third category; a function that looks implemented but has never touched an engine is how the
  `$N::uuid` class of bug ships.

      put_message      VERIFIED   single-table write (fan-out to projections is the port, not this slice)
      get_message      VERIFIED   bucket-derived point read (bucket from the timeuuid via ScyllaCodec)
      list_messages    VERIFIED   real cursor pagination, windowed bucket walk (see below)
      update_message   VERIFIED   resolves the row's bucket via point read, then updates
      delete_message   VERIFIED   same resolution; soft-delete status write
      mark_delivered   VERIFIED   receipt upsert
      mark_read        VERIFIED   receipt upsert
      upsert_reaction  VERIFIED   partition upsert (PK replace = Postgres ON CONFLICT), aggregate read-back
      remove_reaction  VERIFIED   partition delete + the same aggregate
      star_message     VERIFIED   Postgres satellite write (starred_messages stays relational by design)
      unstar_message   VERIFIED   Postgres satellite delete
      list_starred     VERIFIED   Postgres id page (<=50) hydrated by BOUNDED-CONCURRENCY Scylla point reads
      search_messages  STUB       DELIBERATE + PERMANENT-until-decided: no honest Scylla answer exists
                                  (ILIKE over a participant join needs a body index). At flip the
                                  endpoint returns capability error `search.unavailable` — never a
                                  silent empty list. Product regression + its expiry condition are
                                  recorded in DECISION_LOG 2026-08-01: acceptable only while there are
                                  no external users; a rebuildable tsvector INDEX must ship first
                                  otherwise. Do not implement casually — read that entry.

  The six optional callbacks (C4), all VERIFIED live in ScyllaMediaOracleTest:

      poll_vote / list_poll_votes    (iii) validation point-read via get_message (metadata-JSON
                                     delivers the definition); votes stay Postgres poll_votes
      get_by_media_id                (i)   earliest reference from messages_by_media
      media_download_allowed         (i)   THE ORACLE — references+senders from Scylla, ACTIVE
                                     membership live from Postgres; empty references DENY LOUDLY
      list_media                     (i)   gallery projection + viewer window mask (LIMITATION: new
                                     after-viewing materialisation is Postgres-adapter behaviour — a
                                     tracked flip blocker, not a silent drop)
      message_info                   (ii)  receipts partition + one privacy query, reciprocity
                                     applied app-side with the same two halves as Postgres

  ## Media projections (C3 — tables deployed, NOTHING here reads them until C4)

  `messages_by_media` and `media_by_conversation` exist and are shape-verified live
  (ScyllaSchemaShapeTest). THE INVARIANT C4 IMPLEMENTS AGAINST, stated here and in the CQL header so
  it is a rule and not a rediscovery: `messages_by_conversation` is THE AUTHORITY; both projections
  are rebuildable derivations. `media_by_conversation.deleted` is a denormalised tombstone COPY — a
  failed delete fan-out leaves a tombstoned item rendering in the gallery until the projection
  reconciler (C4) converges it; readers treat `deleted` as eventually consistent and never treat the
  projection as evidence a message exists or is live. `messages_by_media` rows survive message
  tombstones BY DESIGN (authorization is by membership, not message liveness).

  ## Pagination and the daily-bucket consequence

  `messages_by_conversation` partitions on `(conversation_id, bucket_date)` — one calendar day per
  partition. A page walks buckets newest-first in #{7}-day windows (one `bucket_date IN` query per
  window, rows merged and time-sorted client-side; timeuuids CLUSTER by embedded time but their
  STRING form does not sort chronologically, hence the codec sort). The walk is capped at
  #{730} days: a conversation idle longer than that lists as EMPTY under this adapter — a real
  behavioural gap vs Postgres, documented here and in the port design (month-sized buckets are the
  fix, and a schema decision that belongs to the port, not this slice). The cursor is
  `"bucket_date|message_id"`, opaque to callers.
  """

  @behaviour MessageService.MessageStore

  import Ecto.Query, only: [where: 3, order_by: 3, limit: 2, offset: 2, select: 3]

  alias MessageService.Persistence.MediaProjections
  alias MessageService.Persistence.MessageReactions
  alias MessageService.Persistence.MessageReceipts
  alias MessageService.Persistence.MessageTimelineReads
  alias MessageService.Persistence.MessageTimelineWrites
  alias MessageService.Persistence.ScyllaCodec
  alias MessageService.Repo
  alias MessageService.Schemas.PollVote
  alias MessageService.Schemas.StarredMessage

  require Logger

  @window_days 7
  @max_lookback_days 730
  @default_limit 50

  @impl true
  def put_message(attrs) do
    plan = MessageTimelineWrites.insert_message_plan(attrs)

    # WRITE-AHEAD INTENT (C6): the webhook outbox row is durable Postgres intent BEFORE the
    # authoritative Scylla put — status='staged', invisible to the dispatcher. Success promotes it
    # to 'pending' (idempotent: only 'staged' flips); a known failure aborts it (kept as evidence);
    # a CRASH between put and promote leaves it staged for the sweeper, which checks Scylla and
    # promotes/aborts. NO LOST WEBHOOK survives; what the same-transaction emit had and this does
    # not is atomicity of the ENQUEUE — stated in the integration guide, not just here.
    app_id = MessageService.WebhookEvents.conversation_app_id(attr(attrs, "conversation_id"))
    {:ok, staged_ids} = stage_webhooks(app_id, attrs)

    with {:ok, client} <- client_adapter(),
         {:ok, _result} <- execute(client, plan) do
      {:ok, _} = SharedInfra.WebhookOutbox.promote_staged(Repo, staged_ids)
      write_media_projections(client, attrs)
      {:ok, response_from_attrs(attrs)}
    else
      {:error, reason} ->
        {:ok, _} =
          SharedInfra.WebhookOutbox.abort_staged(
            Repo,
            staged_ids,
            "scylla put_message failed before promote: #{inspect(reason)}"
          )

        {:error, reason}
    end
  end

  defp stage_webhooks(nil, _attrs), do: {:ok, []}
  defp stage_webhooks(app_id, attrs), do: MessageService.WebhookEvents.stage(app_id, attrs)

  defp write_media_projections(client, attrs) do
    media_id = attr(attrs, "media_id")

    if is_binary(media_id) and media_id != "" do
      reference = MediaProjections.insert_reference_plan(attrs)
      gallery = MediaProjections.upsert_gallery_plan(Map.put(attrs, "deleted", false))

      for plan <- [reference, gallery] do
        case execute(client, plan) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error(
              "MEDIA PROJECTION WRITE FAILED (#{plan.table}) media=#{media_id} " <>
                "conversation=#{attr(attrs, "conversation_id")} message=#{attr(attrs, "message_id")}: " <>
                "#{inspect(reason)} — the oracle will DENY this media until " <>
                "ScyllaAdapter.repair_media_projections/2 runs"
            )
        end
      end
    end

    :ok
  end

  @doc """
  Rebuild both media projections for one message from the AUTHORITY (the stated recovery path for a
  failed fan-out — see 002's invariant). Idempotent: keyed upserts.
  """
  def repair_media_projections(conversation_id, message_id) do
    with {:ok, client} <- client_adapter(),
         {:ok, row, _bucket} <- find_row(client, conversation_id, message_id) do
      attrs = %{
        "conversation_id" => attr(row, "conversation_id"),
        "message_id" => attr(row, "message_id"),
        "media_id" => attr(row, "media_id"),
        "sender_user_id" => attr(row, "sender_user_id"),
        "created_at" => attr(row, "created_at"),
        "metadata" => attr(row, "metadata") || %{},
        "deleted" => not is_nil(attr(row, "deleted_at"))
      }

      if is_binary(attrs["media_id"]) do
        {:ok, _} = execute(client, MediaProjections.insert_reference_plan(attrs))
        {:ok, _} = execute(client, MediaProjections.upsert_gallery_plan(attrs))
      end

      :ok
    end
  end

  @impl true
  def get_message(attrs) do
    with {:ok, client} <- client_adapter() do
      case find_row(client, attr(attrs, "conversation_id"), attr(attrs, "message_id")) do
        {:ok, row, _bucket} -> {:ok, response_from_row(row)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list_messages(attrs) do
    conversation_id = attr(attrs, "conversation_id")
    limit = int_attr(attrs, "limit", @default_limit)

    with {:ok, client} <- client_adapter(),
         {:ok, rows, next_cursor} <- walk_buckets(client, conversation_id, cursor(attrs), limit) do
      {:ok,
       %{
         conversation_id: conversation_id,
         messages: Enum.map(rows, &response_from_row/1),
         next_cursor: next_cursor
       }}
    end
  end

  @impl true
  def update_message(attrs) do
    mutate_resolved(attrs, fn bucket ->
      MessageTimelineWrites.mark_edited_plan(
        attrs
        |> Map.put("bucket_date", bucket)
        |> Map.put_new("edited_at", DateTime.utc_now())
      )
    end)
    |> case do
      {:ok, row} ->
        {:ok, Map.merge(response_from_row(row), %{status: "edited", body: attr(attrs, "body")})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete_message(attrs) do
    mutate_resolved(attrs, fn bucket ->
      MessageTimelineWrites.mark_deleted_plan(
        attrs
        |> Map.put("bucket_date", bucket)
        |> Map.put_new("deleted_at", DateTime.utc_now())
      )
    end)
    |> case do
      {:ok, row} ->
        tombstone_gallery(row)
        {:ok, Map.put(response_from_row(row), :status, "deleted")}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The gallery tombstone: same-primary-key rewrite with deleted=true (replace identity proven by
  # ScyllaSchemaShapeTest). messages_by_media is deliberately NOT touched — authorization is by
  # membership, not message liveness (002's invariant). A failed rewrite leaves the item rendering
  # until repair — LOUD, per the same rule as the fan-out.
  defp tombstone_gallery(row) do
    media_id = attr(row, "media_id")

    if is_binary(media_id) and media_id != "" do
      with {:ok, client} <- client_adapter(),
           {:ok, _} <-
             execute(
               client,
               MediaProjections.upsert_gallery_plan(%{
                 "conversation_id" => attr(row, "conversation_id"),
                 "created_at" => attr(row, "created_at"),
                 "message_id" => attr(row, "message_id"),
                 "media_id" => media_id,
                 "sender_user_id" => attr(row, "sender_user_id"),
                 "metadata" => attr(row, "metadata") || %{},
                 "deleted" => true
               })
             ) do
        :ok
      else
        error ->
          Logger.error(
            "GALLERY TOMBSTONE FAILED conversation=#{attr(row, "conversation_id")} " <>
              "message=#{attr(row, "message_id")}: #{inspect(error)} — item renders until " <>
              "repair_media_projections/2 converges it (002's stated hazard)"
          )
      end
    end

    :ok
  end

  @impl true
  def mark_delivered(attrs), do: put_receipt(Map.merge(attrs, %{"status" => "delivered"}))

  @impl true
  def mark_read(attrs), do: put_receipt(Map.merge(attrs, %{"status" => "read"}))

  # --- reactions: the CQL partition IS the per-message reaction set ---------------------------------
  # PK ((conversation_id, message_id), user_id): an INSERT for an existing (partition, user) REPLACES
  # the row — natively the Postgres ON CONFLICT ... SET emoji semantics (one emoji per user per
  # message). The aggregate is one partition read, grouped client-side; a message's reactions are
  # bounded by its conversation's membership, so the partition stays small.
  @impl true
  def upsert_reaction(attrs) do
    plan =
      MessageReactions.upsert_reaction_plan(%{
        "conversation_id" => attr(attrs, "conversation_id"),
        "message_id" => attr(attrs, "message_id"),
        "user_id" => attr(attrs, "user_id"),
        # Domain says "emoji"; the CQL column says "reaction" — mapped HERE, nowhere else.
        "reaction" => attr(attrs, "emoji"),
        "created_at" => DateTime.utc_now()
      })

    with {:ok, client} <- client_adapter(),
         {:ok, _result} <- execute(client, plan),
         {:ok, reactions} <- reactions_aggregate(client, attrs) do
      {:ok, %{message_id: attr(attrs, "message_id"), reactions: reactions}}
    end
  end

  @impl true
  def remove_reaction(attrs) do
    plan =
      MessageReactions.delete_reaction_plan(%{
        "conversation_id" => attr(attrs, "conversation_id"),
        "message_id" => attr(attrs, "message_id"),
        "user_id" => attr(attrs, "user_id")
      })

    with {:ok, client} <- client_adapter(),
         {:ok, _result} <- execute(client, plan),
         {:ok, reactions} <- reactions_aggregate(client, attrs) do
      {:ok, %{message_id: attr(attrs, "message_id"), reactions: reactions}}
    end
  end

  defp reactions_aggregate(client, attrs) do
    plan =
      MessageReactions.list_for_message_plan(%{
        "conversation_id" => attr(attrs, "conversation_id"),
        "message_id" => attr(attrs, "message_id")
      })

    with {:ok, result} <- execute(client, plan) do
      reactions =
        result
        |> rows()
        |> Enum.frequencies_by(&attr(&1, "reaction"))
        |> Enum.map(fn {emoji, count} -> %{emoji: emoji, count: count} end)
        |> Enum.sort_by(fn %{count: c, emoji: e} -> {-c, e} end)

      {:ok, reactions}
    end
  end

  # --- stars: Postgres ids + Scylla point-reads (the hybrid, by design) ------------------------------
  # starred_messages is a per-user RELATIONAL satellite and stays in Postgres (DECISION_LOG
  # 2026-08-01). The star/unstar writes are identical to the Postgres adapter's; only the HYDRATION
  # differs: the page of ids (<= 50, the existing page_window cap) is resolved to message rows by
  # Scylla point reads at bounded concurrency — worst case 50 reads per page in ~ceil(50/10) waves,
  # NEVER 500 sequential reads for a 500-star user, because pagination bounds the page and
  # async_stream bounds the parallelism. A starred id whose Scylla row is missing (projection drift)
  # is DROPPED from the page with a warning — a shorter page, never a crash and never a phantom row.
  @star_hydration_concurrency 10

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
    page = max(int_attr(attrs, "page", 1), 1)
    limit = int_attr(attrs, "limit", 50)
    offset = (page - 1) * limit

    with {:ok, client} <- client_adapter() do
      id_page =
        StarredMessage
        |> where([s], s.user_id == ^user_id)
        |> order_by([s], desc: s.created_at)
        |> limit(^limit)
        |> offset(^offset)
        |> select([s], {s.conversation_id, s.message_id})
        |> Repo.all()

      hydrated =
        id_page
        |> Task.async_stream(
          fn {conversation_id, message_id} ->
            case find_row(client, conversation_id, message_id) do
              {:ok, row, _bucket} -> response_from_row(row)
              _ -> nil
            end
          end,
          max_concurrency: @star_hydration_concurrency,
          timeout: 10_000,
          on_timeout: :kill_task
        )
        |> Enum.map(fn
          {:ok, row} -> row
          {:exit, _} -> nil
        end)

      dropped = Enum.count(hydrated, &is_nil/1)

      if dropped > 0 do
        require Logger

        Logger.warning(
          "list_starred: #{dropped} starred id(s) had no Scylla row (projection drift) — dropped from page"
        )
      end

      messages =
        hydrated
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Map.put(&1, :is_starred, true))

      {:ok, %{messages: messages, next_cursor: nil}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  # See the moduledoc table: DELIBERATE stub with a recorded product consequence — read
  # DECISION_LOG 2026-08-01 before implementing anything here.
  @impl true
  def search_messages(_attrs), do: {:error, :message_store_unavailable}

  # --- the six optional callbacks (C4), in classification order ------------------------------------

  # (iii) POLLS — reclassification survived contact: the ONLY messages dependency is the validation
  # point-read (re-verified against fetch_poll before porting), which get_message serves — and the
  # poll definition arrives through the metadata-JSON convention (nested map intact, proven live in
  # C1's round-trip). Votes are and stay Postgres (poll_votes).
  @impl true
  def poll_vote(attrs) do
    conversation_id = attr(attrs, "conversation_id")
    user_id = attr(attrs, "user_id")
    option_ids = attrs["option_ids"] || []

    with {:ok, message, definition} <- fetch_scylla_poll(attrs, conversation_id),
         :ok <- valid_scylla_vote_set(definition, option_ids) do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "DELETE FROM poll_votes WHERE message_id = $1::text::uuid AND user_id = $2::text::uuid",
            [message.message_id, user_id]
          )

          if option_ids != [] do
            Repo.query!(
              "INSERT INTO poll_votes (conversation_id, message_id, user_id, option_id) " <>
                "SELECT $1::text::uuid, $2::text::uuid, $3::text::uuid, unnest($4::text[])",
              [message.conversation_id, message.message_id, user_id, option_ids]
            )
          end
        end)

      {:ok,
       %{
         message_id: message.message_id,
         poll:
           MessageService.Polls.build_aggregate(
             definition,
             scylla_poll_votes_of(message.message_id)
           )
       }}
    end
  end

  @impl true
  def list_poll_votes(attrs) do
    conversation_id = attr(attrs, "conversation_id")

    with {:ok, message, definition} <- fetch_scylla_poll(attrs, conversation_id) do
      {:ok,
       %{
         message_id: message.message_id,
         poll:
           MessageService.Polls.build_aggregate(
             definition,
             scylla_poll_votes_of(message.message_id),
             nil
           )
       }}
    end
  end

  # The same gates as PostgresAdapter.fetch_poll, against the Scylla point-read: live poll message in
  # THIS conversation with a definition — anything else :message_not_found (a voter learns nothing
  # about other conversations' messages).
  defp fetch_scylla_poll(attrs, conversation_id) do
    case get_message(attrs) do
      {:ok, %{message_type: "poll", deleted_at: nil, conversation_id: ^conversation_id} = message} ->
        case message.metadata do
          %{"poll" => %{} = definition} -> {:ok, message, definition}
          _ -> {:error, :message_not_found}
        end

      _ ->
        {:error, :message_not_found}
    end
  end

  defp valid_scylla_vote_set(definition, option_ids) do
    known = MapSet.new(definition["options"] || [], & &1["id"])

    cond do
      not Enum.all?(option_ids, &MapSet.member?(known, &1)) -> {:error, :poll_invalid_option}
      length(option_ids) > 1 and definition["allows_multiple"] != true -> {:error, :poll_single_choice}
      true -> :ok
    end
  end

  defp scylla_poll_votes_of(message_id) do
    PollVote
    |> where([v], v.message_id == ^message_id)
    |> order_by([v], asc: v.created_at)
    |> select([v], {v.option_id, v.user_id})
    |> Repo.all()
  end

  # (i) MEDIA — the projections from C3, now read.

  @impl true
  def get_by_media_id(attrs) do
    case attr(attrs, "media_id") do
      media_id when is_binary(media_id) and media_id != "" ->
        with {:ok, client} <- client_adapter(),
             {:ok, result} <- execute(client, MediaProjections.earliest_reference_plan(%{"media_id" => media_id})) do
          case rows(result) do
            [row | _] -> {:ok, %{conversation_id: attr(row, "conversation_id")}}
            [] -> {:error, :not_found}
          end
        end

      _ ->
        {:error, :not_found}
    end
  end

  @doc """
  THE OWNER-ANCHORED DOWNLOAD ORACLE — the rule preserved EXACTLY from the Postgres EXISTS: the viewer
  may download iff some conversation they are an ACTIVE member of contains a message referencing this
  media SENT BY THE ASSET'S OWNER. Split across the stores: the reference set (with senders) comes
  from messages_by_media; the ACTIVE-membership probe stays on authoritative Postgres
  conversation_participants, so left_at is a LIVE deny even though the projection still names the
  conversation.

  FAIL CLOSED, NEVER SILENTLY: an empty reference set denies AND logs loudly — it is either an unsent
  media_id (rare: the gateway's owner fast-path never reaches here for owners) or a LOST PROJECTION
  WRITE, and the two are indistinguishable from here. The silent version of this exact denial once
  cost days. A NON-empty set whose owner-sent conversations simply don't include the viewer is a
  clean deny — that is the rule working, not a fault.
  """
  @impl true
  def media_download_allowed(attrs) do
    with media_id when is_binary(media_id) and media_id != "" <- attr(attrs, "media_id"),
         owner when is_binary(owner) and owner != "" <- attr(attrs, "owner_user_id"),
         viewer when is_binary(viewer) and viewer != "" <- attr(attrs, "viewer_user_id"),
         {:ok, client} <- client_adapter(),
         {:ok, result} <- execute(client, MediaProjections.list_references_plan(%{"media_id" => media_id})) do
      references = rows(result)

      if references == [] do
        Logger.error(
          "media oracle: NO REFERENCES for media=#{media_id} (owner=#{owner}) — denying. " <>
            "Either unsent media or a LOST PROJECTION WRITE; if the message exists, run " <>
            "ScyllaAdapter.repair_media_projections(conversation_id, message_id)"
        )

        {:ok, %{allowed: false}}
      else
        # The sender==owner filter IS the leak defense: a planted reference (someone else re-sending
        # the owner's media_id) must grant nothing.
        conversation_ids =
          references
          |> Enum.filter(&(attr(&1, "sender_user_id") == owner))
          |> Enum.map(&attr(&1, "conversation_id"))
          |> Enum.uniq()

        {:ok, %{allowed: viewer_active_in_any?(viewer, conversation_ids)}}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:ok, %{allowed: false}}
    end
  end

  defp viewer_active_in_any?(_viewer, []), do: false

  defp viewer_active_in_any?(viewer, conversation_ids) do
    %{rows: [[exists]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM conversation_participants " <>
          "WHERE user_id = $1::text::uuid AND left_at IS NULL " <>
          "AND conversation_id = ANY($2::text[]::uuid[]))",
        [viewer, conversation_ids]
      )

    exists
  end

  # The shared-media gallery from the C3 projection, newest first. The viewer's window (cleared_before
  # / auto-delete) comes from their OWN participant row (Postgres) and masks client-side; rows the
  # after-viewing feature ALREADY materialised into user_hidden_messages are excluded. LIMITATION,
  # stated: NEW after-viewing materialisation is a Postgres-adapter behaviour and does not run here —
  # a flip blocker tracked with the port, not silently dropped.
  @impl true
  def list_media(attrs) do
    conversation_id = attr(attrs, "conversation_id")
    viewer = attr(attrs, "viewer_user_id")
    limit = min(int_attr(attrs, "limit", 50), 100)

    with {:ok, client} <- client_adapter(),
         {:ok, result} <-
           execute(
             client,
             MediaProjections.list_gallery_plan(%{
               "conversation_id" => conversation_id,
               "before" => attr(attrs, "before"),
               # Over-fetch: deleted + window-masked rows are filtered below.
               "limit" => limit * 2
             })
           ) do
      raw = rows(result)
      window = viewer_window(conversation_id, viewer)
      hidden = hidden_message_ids(conversation_id, viewer)

      items =
        raw
        |> Enum.reject(&attr(&1, "deleted"))
        |> Enum.reject(&MapSet.member?(hidden, attr(&1, "message_id")))
        |> Enum.filter(&inside_window?(&1, window))
        |> Enum.take(limit)
        |> Enum.map(fn row ->
          %{
            message_id: attr(row, "message_id"),
            media_id: attr(row, "media_id"),
            sender_user_id: attr(row, "sender_user_id"),
            message_type: "media",
            metadata: ScyllaCodec.decode_metadata(attr(row, "metadata")),
            created_at: ScyllaCodec.decode_timestamp(attr(row, "created_at"))
          }
        end)

      next_cursor =
        case List.last(raw) do
          nil -> nil
          last when length(raw) >= limit * 2 -> ScyllaCodec.decode_timestamp(attr(last, "created_at"))
          _ -> nil
        end

      {:ok, %{conversation_id: conversation_id, items: items, next_cursor: next_cursor}}
    end
  end

  defp viewer_window(_conversation_id, nil), do: %{cleared_before: nil, auto_delete_seconds: nil}
  defp viewer_window(_conversation_id, ""), do: %{cleared_before: nil, auto_delete_seconds: nil}

  defp viewer_window(conversation_id, viewer) do
    case Repo.query!(
           "SELECT cleared_before, auto_delete_seconds FROM conversation_participants " <>
             "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
           [conversation_id, viewer]
         ) do
      %{rows: [[cleared, auto]]} -> %{cleared_before: cleared, auto_delete_seconds: auto}
      _ -> %{cleared_before: nil, auto_delete_seconds: nil}
    end
  end

  defp hidden_message_ids(_conversation_id, nil), do: MapSet.new()
  defp hidden_message_ids(_conversation_id, ""), do: MapSet.new()

  defp hidden_message_ids(_conversation_id, viewer) do
    # The table is (user_id, message_id) only — no conversation column (verified against the live
    # schema after assuming otherwise). Message ids are globally unique, so the per-user read is
    # exact; it just can't be conversation-scoped.
    %{rows: rows} =
      Repo.query!(
        "SELECT message_id::text FROM user_hidden_messages WHERE user_id = $1::text::uuid",
        [viewer]
      )

    MapSet.new(rows, fn [id] -> id end)
  end

  defp inside_window?(row, window) do
    created_at = attr(row, "created_at")

    inside_cleared =
      is_nil(window.cleared_before) or DateTime.compare(created_at, window.cleared_before) == :gt

    inside_auto =
      is_nil(window.auto_delete_seconds) or
        DateTime.compare(created_at, DateTime.add(DateTime.utc_now(), -window.auto_delete_seconds, :second)) == :gt

    inside_cleared and inside_auto
  end

  # (ii) MESSAGE_INFO — cross-store composition: message + receipts from Scylla, privacy from
  # Postgres, the reciprocity rule applied app-side with the SAME two halves the Postgres adapter
  # uses (reader half: receipts on unless explicitly off; owner half: viewer_sees_read_receipts?).
  # Same 3 round-trips as the Postgres path's 3 queries.
  @impl true
  def message_info(attrs) do
    conversation_id = attr(attrs, "conversation_id")
    viewer = attr(attrs, "viewer_user_id")

    case get_message(attrs) do
      {:error, reason} ->
        {:error, reason}

      {:ok, message} ->
        cond do
          message.conversation_id != conversation_id -> {:error, :message_not_found}
          not is_nil(message.deleted_at) -> {:error, :message_not_found}
          message.sender_user_id != viewer -> {:error, :not_sender}
          true -> build_scylla_message_info(message, viewer)
        end
    end
  end

  defp build_scylla_message_info(message, viewer) do
    with {:ok, client} <- client_adapter(),
         {:ok, result} <-
           execute(
             client,
             MessageReceipts.list_for_message_plan(%{
               "conversation_id" => message.conversation_id,
               "message_id" => message.message_id
             })
           ) do
      receipt_rows =
        result |> rows() |> Enum.reject(&(attr(&1, "user_id") == viewer))

      visible = privacy_visibility(Enum.map(receipt_rows, &attr(&1, "user_id")))
      show_read = MessageService.ReadReceipts.viewer_sees_read_receipts?(viewer)

      read =
        if show_read do
          receipt_rows
          |> Enum.filter(fn row ->
            attr(row, "read_at") != nil and Map.get(visible, attr(row, "user_id"), true)
          end)
          |> Enum.sort_by(&attr(&1, "read_at"), {:desc, DateTime})
          |> Enum.map(&%{user_id: attr(&1, "user_id"), read_at: attr(&1, "read_at")})
        else
          []
        end

      read_ids = MapSet.new(read, & &1.user_id)

      delivered =
        receipt_rows
        |> Enum.filter(fn row ->
          (attr(row, "delivered_at") || attr(row, "read_at")) &&
            not MapSet.member?(read_ids, attr(row, "user_id"))
        end)
        |> Enum.map(&%{user_id: attr(&1, "user_id"), delivered_at: attr(&1, "delivered_at") || attr(&1, "read_at")})
        |> Enum.sort_by(& &1.delivered_at, {:desc, DateTime})

      {:ok,
       %{
         conversation_id: message.conversation_id,
         message_id: message.message_id,
         sender_user_id: message.sender_user_id,
         read: read,
         delivered: delivered,
         read_hidden: not show_read
       }}
    end
  end

  # The reader half of reciprocity, resolved in ONE Postgres query: enabled unless a privacy row says
  # explicitly false (missing row = enabled — read_receipts_on's NULL semantics, restated app-side).
  defp privacy_visibility([]), do: %{}

  defp privacy_visibility(user_ids) do
    %{rows: rows} =
      Repo.query!(
        "SELECT user_id::text, read_receipts_enabled FROM user_privacy_settings " <>
          "WHERE user_id = ANY($1::text[]::uuid[])",
        [user_ids]
      )

    Map.new(rows, fn [user_id, enabled] -> {user_id, enabled != false} end)
  end

  # --- point read + bucket resolution --------------------------------------------------------------

  # The partition key includes bucket_date, which callers don't carry — derive candidate days from the
  # timeuuid (the day it encodes, plus the previous day for the midnight race) and try each: at most
  # two point reads, usually one.
  defp find_row(client, conversation_id, message_id) do
    candidates = ScyllaCodec.bucket_candidates(message_id)

    if candidates == [] do
      {:error, :message_not_found}
    else
      Enum.reduce_while(candidates, {:error, :message_not_found}, fn bucket, acc ->
        plan =
          MessageTimelineReads.get_message_plan(%{
            "conversation_id" => conversation_id,
            "bucket_date" => bucket,
            "message_id" => message_id
          })

        case execute(client, plan) do
          {:ok, result} ->
            case rows(result) do
              [row | _] -> {:halt, {:ok, row, bucket}}
              [] -> {:cont, acc}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  # update/delete need the row's REAL bucket (it is part of the primary key): resolve via point read
  # first — which also gives the not-found answer for free — then run the mutation against it.
  defp mutate_resolved(attrs, plan_fun) do
    with {:ok, client} <- client_adapter(),
         {:ok, row, bucket} <-
           find_row(client, attr(attrs, "conversation_id"), attr(attrs, "message_id")),
         {:ok, _result} <- execute(client, plan_fun.(bucket)) do
      {:ok, row}
    end
  end

  # --- pagination ----------------------------------------------------------------------------------

  defp cursor(attrs) do
    with cursor when is_binary(cursor) <- attr(attrs, "cursor") || attr(attrs, "before"),
         [date_part, id_part] <- String.split(cursor, "|", parts: 2),
         {:ok, date} <- Date.from_iso8601(date_part) do
      {date, id_part}
    else
      _ -> nil
    end
  end

  defp walk_buckets(client, conversation_id, cursor, limit) do
    {anchor, before_id} =
      case cursor do
        {date, id} -> {date, id}
        nil -> {Date.utc_today(), nil}
      end

    do_walk(client, conversation_id, anchor, before_id, limit, [], @max_lookback_days)
  end

  defp do_walk(_client, _conversation_id, _anchor, _before_id, _limit, acc, days_left)
       when days_left <= 0 do
    # Lookback exhausted: whatever we found is the last page. See the moduledoc for what this means
    # for conversations idle longer than the cap.
    {:ok, acc, nil}
  end

  # ONE QUERY PER BUCKET, merged client-side. The first cut used a single `bucket_date IN (...)`
  # window query — and the first live run against a real engine caught it: Scylla applies LIMIT in
  # TOKEN order across the IN partitions, truncating before any client-side time sort can run, so an
  # old bucket whose token sorts first could shadow the newest messages entirely. Per-bucket queries
  # (clustering DESC gives newest-first WITHIN each partition) + merge + take is correct by
  # construction: up to #{@window_days} point-partition reads per window, each LIMIT-bounded.
  defp do_walk(client, conversation_id, anchor, before_id, limit, acc, days_left) do
    window = for offset <- 0..(@window_days - 1), do: Date.add(anchor, -offset)
    remaining = limit - length(acc)

    fetched_result =
      Enum.reduce_while(window, {:ok, []}, fn bucket, {:ok, collected} ->
        plan = bucket_plan(conversation_id, bucket, before_id, remaining)

        case execute(client, plan) do
          {:ok, result} -> {:cont, {:ok, collected ++ rows(result)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case fetched_result do
      {:ok, fetched} ->
        # timeuuid STRINGS don't sort chronologically — sort by the embedded timestamp, newest first.
        acc =
          acc ++ (fetched |> Enum.sort_by(&timeuuid_sort_key/1, :desc) |> Enum.take(remaining))

        if length(acc) >= limit do
          {:ok, acc, next_cursor(acc)}
        else
          next_anchor = Date.add(anchor, -@window_days)

          do_walk(
            client,
            conversation_id,
            next_anchor,
            before_id,
            limit,
            acc,
            days_left - @window_days
          )
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bucket_plan(conversation_id, bucket, nil, limit) do
    MessageTimelineReads.list_recent_plan(%{
      "conversation_id" => conversation_id,
      "bucket_date" => bucket,
      "limit" => limit
    })
  end

  defp bucket_plan(conversation_id, bucket, before_id, limit) do
    MessageTimelineReads.list_before_plan(%{
      "conversation_id" => conversation_id,
      "bucket_date" => bucket,
      "before_message_id" => before_id,
      "limit" => limit
    })
  end

  defp timeuuid_sort_key(row) do
    case ScyllaCodec.timeuuid_to_datetime(attr(row, "message_id")) do
      {:ok, dt} -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp next_cursor([]), do: nil

  defp next_cursor(rows_list) do
    oldest = List.last(rows_list)

    case ScyllaCodec.timeuuid_to_datetime(attr(oldest, "message_id")) do
      {:ok, dt} -> "#{DateTime.to_date(dt)}|#{attr(oldest, "message_id")}"
      _ -> nil
    end
  end

  # --- receipts ------------------------------------------------------------------------------------

  defp put_receipt(attrs) do
    plan =
      MessageReceipts.upsert_receipt_plan(Map.put_new(attrs, "updated_at", DateTime.utc_now()))

    with {:ok, client} <- client_adapter(),
         {:ok, _result} <- execute(client, plan) do
      {:ok, receipt_response(attrs)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # --- plumbing ------------------------------------------------------------------------------------

  defp client_adapter do
    case Application.get_env(:message_service, :scylla_client_adapter, SharedInfra.Scylla.Client) do
      adapter when is_atom(adapter) -> {:ok, adapter}
      _ -> {:error, :message_store_unavailable}
    end
  end

  # ERROR NORMALIZATION — a drill finding, not a guess: with the cluster process alive but the node
  # down, Xandra returns {:error, %Xandra.ConnectionError{}} — NOT :scylla_unavailable — and a raw
  # struct falls through every gateway clause to a 400 "invalid request". A store outage must be
  # :message_store_unavailable (503 at the gateway), whatever shape the driver reports it in.
  defp execute(client, plan) do
    case client.execute(plan.statement, plan.params, scylla_config()) do
      {:error, :scylla_unavailable} ->
        {:error, :message_store_unavailable}

      {:error, %{__struct__: struct} = error}
      when struct in [Xandra.ConnectionError, Xandra.Error] ->
        Logger.warning("scylla #{plan.operation}: #{Exception.message(error)} -> store unavailable")
        {:error, :message_store_unavailable}

      result ->
        result
    end
  end

  defp scylla_config do
    MessageService.Infrastructure.scylla_config()
  end

  defp rows(%{rows: rows}) when is_list(rows), do: rows
  defp rows(%{"rows" => rows}) when is_list(rows), do: rows
  defp rows(rows) when is_list(rows), do: rows
  defp rows(_result), do: []

  # Response from INPUT attrs (put_message): metadata is already in domain form; timestamps may be
  # DateTimes — normalise to the ISO strings every other adapter emits.
  defp response_from_attrs(attrs) do
    %{
      conversation_id: attr(attrs, "conversation_id"),
      message_id: attr(attrs, "message_id"),
      sender_user_id: attr(attrs, "sender_user_id"),
      message_type: attr(attrs, "message_type"),
      body: attr(attrs, "body"),
      media_id: attr(attrs, "media_id"),
      reply_to_message_id: attr(attrs, "reply_to_message_id"),
      status: attr(attrs, "status"),
      metadata: attr(attrs, "metadata") || %{},
      created_at: ScyllaCodec.decode_timestamp(attr(attrs, "created_at")),
      edited_at: ScyllaCodec.decode_timestamp(attr(attrs, "edited_at")),
      deleted_at: ScyllaCodec.decode_timestamp(attr(attrs, "deleted_at"))
    }
  end

  # Response from a Xandra ROW: metadata values are JSON-encoded text (the ScyllaCodec convention),
  # timestamps are DateTimes, uuids are strings. bucket_date is internal and never emitted.
  defp response_from_row(row) do
    %{
      conversation_id: attr(row, "conversation_id"),
      message_id: attr(row, "message_id"),
      sender_user_id: attr(row, "sender_user_id"),
      message_type: attr(row, "message_type"),
      body: attr(row, "body"),
      media_id: attr(row, "media_id"),
      reply_to_message_id: attr(row, "reply_to_message_id"),
      status: attr(row, "status"),
      metadata: ScyllaCodec.decode_metadata(attr(row, "metadata")),
      created_at: ScyllaCodec.decode_timestamp(attr(row, "created_at")),
      edited_at: ScyllaCodec.decode_timestamp(attr(row, "edited_at")),
      deleted_at: ScyllaCodec.decode_timestamp(attr(row, "deleted_at"))
    }
  end

  defp receipt_response(attrs) do
    %{
      conversation_id: attr(attrs, "conversation_id"),
      message_id: attr(attrs, "message_id"),
      user_id: attr(attrs, "user_id"),
      status: attr(attrs, "status"),
      updated_at: ScyllaCodec.decode_timestamp(attr(attrs, "updated_at"))
    }
  end

  defp attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  # THE HTTP-BOUNDARY COERCION (production flip finding, 2026-08-01). Numeric params cross the
  # internal HTTP API as JSON STRINGS — the gateway forwards raw query params ("50"), Plug.Parsers
  # hands them over verbatim, and this adapter did ARITHMETIC on them where Postgres/Ecto silently
  # cast; every chat open crashed with ArithmeticError. Every numeric parameter is coerced HERE,
  # once, at the adapter's entry — never at call sites. The remaining HTTP-borne params are
  # string-typed BY DESIGN and already handled: ids and cursors are strings; ScyllaCodec accepts ISO
  # strings for timestamps and dates; option_ids is a string list; metadata is a map.
  defp int_attr(attrs, key, default) do
    case attr(attrs, key) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end

defmodule MessageService.MessageStore.DualWriteAdapter do
  @moduledoc """
  C7: POSTGRES AUTHORITATIVE, SCYLLA SHADOW. Every callback delegates to the PostgresAdapter —
  identical results, identical latency, identical webhooks/inbox maintenance (all of that happens
  inside the Postgres adapter's own transaction, untouched). After a successful WRITE, the same data
  is mirrored into Scylla via MessageService.ShadowMirror: detached supervised task, bounded
  timeouts, failures RECORDED in scylla_mirror_failures — never surfaced to the caller. Reads never
  touch Scylla.

  Selected by MESSAGE_STORE_ADAPTER=dual_write (runtime.exs). DEFAULT IS UNCHANGED (postgres):
  deploying this code with the flag unset changes nothing observable — the module is simply never
  in the call path.

  The six optional callbacks delegate to Postgres too (the flip, not the shadow, moves them);
  poll votes / stars are Postgres either way.
  """

  @behaviour MessageService.MessageStore

  alias MessageService.MessageStore.PostgresAdapter
  alias MessageService.ShadowMirror

  # --- writes: delegate, then mirror the COMMITTED result ------------------------------------------

  @impl true
  def put_message(attrs) do
    with {:ok, response} <- PostgresAdapter.put_message(attrs) do
      ShadowMirror.mirror_put(mirror_attrs(response))
      {:ok, response}
    end
  end

  @impl true
  def update_message(attrs) do
    with {:ok, response} <- PostgresAdapter.update_message(attrs) do
      ShadowMirror.mirror_edit(mirror_attrs(response))
      {:ok, response}
    end
  end

  @impl true
  def delete_message(attrs) do
    with {:ok, response} <- PostgresAdapter.delete_message(attrs) do
      ShadowMirror.mirror_delete(mirror_attrs(response))
      {:ok, response}
    end
  end

  @impl true
  def mark_delivered(attrs) do
    with {:ok, response} <- PostgresAdapter.mark_delivered(attrs) do
      ShadowMirror.mirror_receipt(receipt_attrs(response, "delivered"))
      {:ok, response}
    end
  end

  @impl true
  def mark_read(attrs) do
    with {:ok, response} <- PostgresAdapter.mark_read(attrs) do
      ShadowMirror.mirror_receipt(receipt_attrs(response, "read"))
      {:ok, response}
    end
  end

  @impl true
  def upsert_reaction(attrs) do
    with {:ok, response} <- PostgresAdapter.upsert_reaction(attrs) do
      ShadowMirror.mirror_reaction(%{
        "conversation_id" => dwattr(attrs, "conversation_id"),
        "message_id" => dwattr(attrs, "message_id"),
        "user_id" => dwattr(attrs, "user_id"),
        "reaction" => dwattr(attrs, "emoji"),
        "created_at" => DateTime.utc_now()
      })

      {:ok, response}
    end
  end

  @impl true
  def remove_reaction(attrs) do
    with {:ok, response} <- PostgresAdapter.remove_reaction(attrs) do
      ShadowMirror.mirror_reaction(%{
        "conversation_id" => dwattr(attrs, "conversation_id"),
        "message_id" => dwattr(attrs, "message_id"),
        "user_id" => dwattr(attrs, "user_id"),
        "__reaction_op" => "remove"
      })

      {:ok, response}
    end
  end

  # --- everything else: Postgres, verbatim ----------------------------------------------------------

  @impl true
  defdelegate get_message(attrs), to: PostgresAdapter
  @impl true
  defdelegate list_messages(attrs), to: PostgresAdapter
  @impl true
  defdelegate star_message(attrs), to: PostgresAdapter
  @impl true
  defdelegate unstar_message(attrs), to: PostgresAdapter
  @impl true
  defdelegate list_starred(attrs), to: PostgresAdapter
  @impl true
  defdelegate search_messages(attrs), to: PostgresAdapter
  @impl true
  defdelegate list_media(attrs), to: PostgresAdapter
  @impl true
  defdelegate get_by_media_id(attrs), to: PostgresAdapter
  @impl true
  defdelegate message_info(attrs), to: PostgresAdapter
  @impl true
  defdelegate poll_vote(attrs), to: PostgresAdapter
  @impl true
  defdelegate list_poll_votes(attrs), to: PostgresAdapter
  @impl true
  defdelegate media_download_allowed(attrs), to: PostgresAdapter

  # The COMMITTED response is the mirror's source (not the caller's attrs): it carries the stamped
  # fields exactly as Postgres holds them, so both stores derive from one authority.
  defp mirror_attrs(response) do
    created_at = response[:created_at] || response["created_at"]

    %{
      "conversation_id" => response[:conversation_id],
      "bucket_date" => created_at |> bucket_date(),
      "message_id" => response[:message_id],
      "sender_user_id" => response[:sender_user_id],
      "message_type" => response[:message_type],
      "body" => response[:body],
      "media_id" => response[:media_id],
      "reply_to_message_id" => response[:reply_to_message_id],
      "status" => response[:status],
      "metadata" => response[:metadata] || %{},
      "created_at" => created_at,
      "edited_at" => response[:edited_at],
      "deleted_at" => response[:deleted_at]
    }
  end

  defp receipt_attrs(response, status) do
    %{
      "conversation_id" => response[:conversation_id],
      "message_id" => response[:message_id],
      "user_id" => response[:user_id],
      "status" => status,
      "updated_at" => response[:updated_at] || DateTime.utc_now()
    }
  end

  defp bucket_date(%DateTime{} = dt), do: dt |> DateTime.to_date() |> Date.to_iso8601()
  defp bucket_date(%NaiveDateTime{} = dt), do: dt |> NaiveDateTime.to_date() |> Date.to_iso8601()
  defp bucket_date(value) when is_binary(value), do: String.slice(value, 0, 10)
  defp bucket_date(_), do: nil

  defp dwattr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
end

defmodule MessageService.MessageStore.ShadowReadAdapter do
  @moduledoc """
  C8 phase 2 — THE SHADOW-READ COMPARATOR. Writes ARE DualWriteAdapter writes (Postgres
  authoritative + Scylla mirror, unchanged); reads are served from Postgres AND replayed against
  Scylla in a detached task that field-compares the answers. A divergence is RECORDED into
  scylla_mirror_failures with op='read_diff' (same table the C7 verification report counts, so the
  C8 gate sees read-path divergence through the same lens) — the USER never sees the comparison,
  its latency, or its failures.

  Selected by MESSAGE_STORE_ADAPTER=shadow_read. Exit criterion for this phase: zero new read_diff
  rows over an agreed quiet window (the runbook says 48h) alongside the C7 gate.
  """

  @behaviour MessageService.MessageStore

  alias MessageService.MessageStore.DualWriteAdapter
  alias MessageService.MessageStore.PostgresAdapter
  alias MessageService.MessageStore.ScyllaAdapter
  alias MessageService.Repo

  require Logger

  # Writes: exactly dual-write.
  @impl true
  defdelegate put_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate update_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate delete_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate mark_delivered(attrs), to: DualWriteAdapter
  @impl true
  defdelegate mark_read(attrs), to: DualWriteAdapter
  @impl true
  defdelegate upsert_reaction(attrs), to: DualWriteAdapter
  @impl true
  defdelegate remove_reaction(attrs), to: DualWriteAdapter
  @impl true
  defdelegate star_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate unstar_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate poll_vote(attrs), to: DualWriteAdapter

  # Reads the comparator shadows: the two the flip changes most.
  @impl true
  def get_message(attrs) do
    result = PostgresAdapter.get_message(attrs)
    shadow_compare(:get_message, attrs, result)
    result
  end

  @impl true
  def list_messages(attrs) do
    result = PostgresAdapter.list_messages(attrs)
    shadow_compare(:list_messages, attrs, result)
    result
  end

  # Reads served plainly from Postgres (compared implicitly by the C7 report instead).
  @impl true
  defdelegate list_starred(attrs), to: PostgresAdapter
  @impl true
  defdelegate search_messages(attrs), to: PostgresAdapter
  @impl true
  defdelegate list_media(attrs), to: PostgresAdapter
  @impl true
  defdelegate get_by_media_id(attrs), to: PostgresAdapter
  @impl true
  defdelegate message_info(attrs), to: PostgresAdapter
  @impl true
  defdelegate list_poll_votes(attrs), to: PostgresAdapter
  @impl true
  defdelegate media_download_allowed(attrs), to: PostgresAdapter

  defp shadow_compare(op, attrs, {:ok, authoritative}) do
    run = fn ->
      case scylla_result(op, attrs) do
        {:ok, shadow} ->
          case diff(op, authoritative, shadow) do
            nil -> :ok
            reason -> record_diff(op, attrs, reason)
          end

        {:error, :message_store_unavailable} ->
          # An unavailable shadow is C7's lane (mirror failures) — not a read divergence.
          :ok

        {:error, reason} ->
          record_diff(op, attrs, "shadow read errored: #{inspect(reason)}")
      end
    end

    if Application.get_env(:message_service, :scylla_shadow_async, true) do
      Task.Supervisor.start_child(MessageService.ShadowMirror.TaskSupervisor, run)
    else
      run.()
    end

    :ok
  end

  defp shadow_compare(_op, _attrs, _error), do: :ok

  defp scylla_result(:get_message, attrs), do: ScyllaAdapter.get_message(attrs)
  defp scylla_result(:list_messages, attrs), do: ScyllaAdapter.list_messages(attrs)

  defp diff(:get_message, pg, sc) do
    cond do
      pg.body != sc.body -> "body diverged"
      pg.status != sc.status -> "status diverged"
      true -> nil
    end
  end

  defp diff(:list_messages, pg, sc) do
    pg_ids = Enum.map(pg.messages, & &1.message_id)
    sc_ids = Enum.map(sc.messages, & &1.message_id)

    if pg_ids == sc_ids, do: nil, else: "page ids diverged (pg=#{length(pg_ids)} sc=#{length(sc_ids)})"
  end

  defp record_diff(op, attrs, reason) do
    Repo.query!(
      "INSERT INTO scylla_mirror_failures (conversation_id, message_id, op, reason) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, $4)",
      [
        attrs["conversation_id"] || Map.get(attrs, :conversation_id),
        attrs["message_id"] || Map.get(attrs, :message_id) ||
          "00000000-0000-0000-0000-000000000000",
        "read_diff",
        "#{op}: #{reason}"
      ]
    )

    :ok
  rescue
    error ->
      Logger.error("shadow read: failed to record diff: #{Exception.message(error)}")
      :ok
  end
end

defmodule MessageService.MessageStore.ScyllaReadAdapter do
  @moduledoc """
  C8 phase 3 — THE FLIP, with the rollback held open: READS from Scylla, WRITES still dual (Postgres
  never stops receiving them — which is exactly what makes rollback lossless and instant). Selected
  by MESSAGE_STORE_ADAPTER=scylla_read. ROLLBACK = select `postgres` (or `dual_write`) again: a
  remote-console `Application.put_env` takes effect on the next call — measured in the drill — with
  the env var updated afterwards for restart durability.

  search_messages surfaces the recorded degradation (503 `search.unavailable` at the gateway) per
  DECISION_LOG 2026-08-01.
  """

  @behaviour MessageService.MessageStore

  alias MessageService.MessageStore.DualWriteAdapter
  alias MessageService.MessageStore.PostgresAdapter
  alias MessageService.MessageStore.ScyllaAdapter

  # Writes: dual, Postgres authoritative — the rollback insurance.
  @impl true
  defdelegate put_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate update_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate delete_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate mark_delivered(attrs), to: DualWriteAdapter
  @impl true
  defdelegate mark_read(attrs), to: DualWriteAdapter
  @impl true
  defdelegate upsert_reaction(attrs), to: DualWriteAdapter
  @impl true
  defdelegate remove_reaction(attrs), to: DualWriteAdapter
  @impl true
  defdelegate star_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate unstar_message(attrs), to: DualWriteAdapter
  @impl true
  defdelegate poll_vote(attrs), to: ScyllaAdapter

  # Reads: Scylla serves.
  @impl true
  defdelegate get_message(attrs), to: ScyllaAdapter
  @impl true
  defdelegate list_messages(attrs), to: ScyllaAdapter
  @impl true
  defdelegate list_starred(attrs), to: ScyllaAdapter
  @impl true
  defdelegate list_media(attrs), to: ScyllaAdapter
  @impl true
  defdelegate get_by_media_id(attrs), to: ScyllaAdapter
  @impl true
  defdelegate message_info(attrs), to: ScyllaAdapter
  @impl true
  defdelegate list_poll_votes(attrs), to: ScyllaAdapter
  @impl true
  defdelegate media_download_allowed(attrs), to: ScyllaAdapter
  # SEARCH IS SERVED BY POSTGRES, not Scylla — and that is not an oversight.
  #
  # Scylla has no honest search answer (ILIKE over a participant join needs a body index). Postgres
  # DOES have the data, right now, because writes above are still dual — the same rollback insurance
  # that makes this adapter safe is what keeps `messages` complete. See
  # PostgresAdapter.search_messages/1 for the expiry: this dies when dual-write ends.
  @impl true
  defdelegate search_messages(attrs), to: PostgresAdapter
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

  # In-memory twins of the Postgres poll ops: same gates, same replace-the-set semantics, the SAME
  # shared MessageService.Polls.build_aggregate — so the aggregate shape cannot drift between adapters.
  @impl true
  def poll_vote(attrs) do
    ensure_started()
    conversation_id = attrs["conversation_id"]
    message_id = attrs["message_id"]
    user_id = attrs["user_id"]
    option_ids = attrs["option_ids"] || []

    Agent.get_and_update(@name, fn state ->
      message =
        Enum.find(
          state.messages,
          &(&1.message_id == message_id and &1.conversation_id == conversation_id and
              &1.message_type == "poll" and is_nil(&1[:deleted_at]))
        )

      definition = message && message.metadata["poll"]
      known = definition && MapSet.new(definition["options"] || [], & &1["id"])

      cond do
        is_nil(definition) ->
          {{:error, :message_not_found}, state}

        not Enum.all?(option_ids, &MapSet.member?(known, &1)) ->
          {{:error, :poll_invalid_option}, state}

        length(option_ids) > 1 and definition["allows_multiple"] != true ->
          {{:error, :poll_single_choice}, state}

        true ->
          kept =
            Enum.reject(
              state.poll_votes,
              &(&1.message_id == message_id and &1.user_id == user_id)
            )

          added =
            Enum.map(option_ids, &%{message_id: message_id, user_id: user_id, option_id: &1})

          votes = kept ++ added
          pairs = for v <- votes, v.message_id == message_id, do: {v.option_id, v.user_id}

          {{:ok,
            %{
              message_id: message_id,
              poll: MessageService.Polls.build_aggregate(definition, pairs)
            }}, %{state | poll_votes: votes}}
      end
    end)
  end

  @impl true
  def list_poll_votes(attrs) do
    ensure_started()
    conversation_id = attrs["conversation_id"]
    message_id = attrs["message_id"]

    Agent.get(@name, fn state ->
      message =
        Enum.find(
          state.messages,
          &(&1.message_id == message_id and &1.conversation_id == conversation_id and
              &1.message_type == "poll" and is_nil(&1[:deleted_at]))
        )

      case message && message.metadata["poll"] do
        nil ->
          {:error, :message_not_found}

        definition ->
          pairs =
            for v <- state.poll_votes, v.message_id == message_id, do: {v.option_id, v.user_id}

          {:ok,
           %{
             message_id: message_id,
             poll: MessageService.Polls.build_aggregate(definition, pairs, nil)
           }}
      end
    end)
  end

  # In-memory twin of the Postgres message_info: same gates (tombstone → not_found, sender-only) and the
  # same read/delivered split (received = delivered_at OR read_at). NO privacy filtering — this adapter
  # has no user_privacy_settings, matching its receipt_counts (which doesn't filter either).
  @impl true
  def message_info(attrs) do
    ensure_started()
    conversation_id = attrs["conversation_id"]
    message_id = attrs["message_id"]
    viewer = attrs["viewer_user_id"]

    Agent.get(@name, fn state ->
      message =
        Enum.find(
          state.messages,
          &(&1.conversation_id == conversation_id and &1.message_id == message_id)
        )

      cond do
        is_nil(message) or not is_nil(message[:deleted_at]) ->
          {:error, :message_not_found}

        message.sender_user_id != viewer ->
          {:error, :not_sender}

        true ->
          rows =
            Enum.filter(
              state.receipts,
              &(&1.conversation_id == conversation_id and &1.message_id == message_id and
                  &1.user_id != viewer)
            )

          read =
            rows
            |> Enum.filter(& &1[:read_at])
            |> Enum.map(&%{user_id: &1.user_id, read_at: &1[:read_at]})

          read_ids = MapSet.new(read, & &1.user_id)

          delivered =
            rows
            |> Enum.filter(
              &((&1[:delivered_at] || &1[:read_at]) and not MapSet.member?(read_ids, &1.user_id))
            )
            |> Enum.map(&%{user_id: &1.user_id, delivered_at: &1[:delivered_at] || &1[:read_at]})

          {:ok,
           %{
             conversation_id: conversation_id,
             message_id: message_id,
             sender_user_id: viewer,
             read: read,
             delivered: delivered,
             read_hidden: false
           }}
      end
    end)
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
    do: %{messages: [], receipts: [], reactions: [], stars: [], participants: [], poll_votes: []}

  # UNLINKED on purpose. This lazy-start runs inside whatever process first calls the adapter — in
  # tests, a TEST PROCESS. `Agent.start_link` would tie the shared agent's life to that test: the agent
  # dies with it, and the next caller races the death (whereis says alive, the call says no process).
  # That race produced real CI flakes ("join crashed" in channels_test; sandbox checkout deaths). An
  # explicitly supervised start_link/1 remains available for supervision trees.
  defp ensure_started do
    case Process.whereis(@name) do
      nil ->
        case Agent.start(fn -> initial_state() end, name: @name) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end
end

defmodule MessageService.MessageStore.PostgresAdapter do
  require Logger

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

  # The read-receipt reciprocity predicate lives in ONE place (MessageService.ReadReceipts) so the
  # aggregate, the per-message reader list, and the status viewer lists provably share it.
  import MessageService.ReadReceipts

  alias MessageService.Repo
  alias MessageService.Schemas.Message
  alias MessageService.Schemas.MessageReaction
  alias MessageService.Schemas.MessageReceipt
  alias MessageService.Schemas.PollVote
  alias MessageService.Schemas.StarredMessage
  alias MessageService.VisibilityWindow

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
              # Denormalised inbox row (086): maintained INSIDE this transaction, so under the
              # Postgres store the counter/preview can never drift from the message that caused them.
              MessageService.InboxProjection.record_message(message)
              emit_message_created(app_id, message)
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

  # Webhooks speak the integrator's EXTERNAL ids — the ids they mint tokens with and pass to /v1. An
  # internal uuid is meaningless to them and a boundary leak, so the sender is resolved to their external
  # id UNDER THE CONVERSATION'S app_id (the authoritative tenant, in scope from this same transaction).
  # Unresolvable — the user row is gone, or it's a first-party (phone/email) user with no external_id —
  # → the event is DROPPED, never emitted with an internal or blank id (the call webhooks'
  # unattributable-drop rule). Cost: one indexed PK lookup inside the write txn.
  defp emit_message_created(app_id, %Message{} = message) do
    # Shared with the Scylla adapter's stage path (C6) so the event wire shape cannot drift.
    MessageService.WebhookEvents.emit(app_id, %{
      message_id: message.message_id,
      conversation_id: message.conversation_id,
      sender_user_id: message.sender_user_id,
      message_type: message.message_type,
      body: message.body,
      created_at: message.created_at
    })
  end


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
    cursor = parse_cursor(attrs)

    rows =
      Message
      |> where([m], m.conversation_id == ^conversation_id)
      |> apply_viewer_window(conversation_id, viewer)
      |> apply_keyset(cursor)
      |> limit(^limit)
      |> Repo.all()

    message_ids = Enum.map(rows, & &1.message_id)

    # read_by_count already EXCLUDES readers who disabled read receipts (the reader half — a JOIN inside
    # receipt_counts, still ONE query). delivered_by_count is unaffected.
    counts = receipt_counts(conversation_id, message_ids)
    reactions = reaction_summaries(message_ids, viewer)
    starred = starred_set(message_ids, viewer)
    polls = poll_summaries(rows)

    # The viewer half (reciprocity): a viewer who disabled read receipts sees NO read_by_count at all. ONE
    # lookup for the whole page (not per message), applied below.
    show_read = viewer_sees_read_receipts?(viewer)

    messages =
      Enum.map(rows, fn message ->
        message
        |> message_response()
        |> Map.merge(
          Map.get(counts, message.message_id, %{read_by_count: 0, delivered_by_count: 0})
        )
        |> Map.merge(Map.get(reactions, message.message_id, %{reactions: [], my_reaction: nil}))
        |> Map.put(:is_starred, MapSet.member?(starred, message.message_id))
        |> merge_poll(Map.get(polls, message.message_id))
        |> hide_read_count(show_read)
      end)

    {:ok,
     %{
       conversation_id: conversation_id,
       messages: messages,
       next_cursor: next_cursor(rows, limit)
     }}
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  # Compound (created_at, message_id) keyset pagination. Additive: with NO cursor params this is the
  # unchanged "recent" page (newest first) — only the always-nil next_cursor becomes real. Forward
  # (after_*) backfills oldest→newest strictly after a point; backward (before_*) scrolls history
  # newest→older strictly before a point. The message_id tiebreak (the uuid PK) means same-timestamp
  # rows are never skipped — mirrors the webhook outbox list_failed keyset ((created_at, id) < ($ts, $id)),
  # using the same $N::text::timestamptz / $N::text::uuid cast convention.
  defp parse_cursor(attrs) do
    after_ts = attr(attrs, "after_created_at")
    after_id = attr(attrs, "after_id")
    before_ts = attr(attrs, "before_created_at")
    before_id = attr(attrs, "before_id")

    cond do
      present?(after_ts) and present?(after_id) -> {:forward, after_ts, after_id}
      present?(before_ts) and present?(before_id) -> {:backward, before_ts, before_id}
      true -> :recent
    end
  end

  defp apply_keyset(query, {:forward, ts, id}) do
    query
    |> where(
      [m],
      fragment(
        "(?, ?) > (?::text::timestamptz, ?::text::uuid)",
        m.created_at,
        m.message_id,
        ^ts,
        ^id
      )
    )
    |> order_by([m], asc: m.created_at, asc: m.message_id)
  end

  defp apply_keyset(query, {:backward, ts, id}) do
    query
    |> where(
      [m],
      fragment(
        "(?, ?) < (?::text::timestamptz, ?::text::uuid)",
        m.created_at,
        m.message_id,
        ^ts,
        ^id
      )
    )
    |> order_by([m], desc: m.created_at, desc: m.message_id)
  end

  # Recent (no cursor): unchanged newest-first, now with a deterministic message_id tiebreak so
  # same-timestamp rows have a stable order (and a usable next_cursor).
  defp apply_keyset(query, :recent) do
    order_by(query, [m], desc: m.created_at, desc: m.message_id)
  end

  # next_cursor = the keyset of the LAST row in the page, but only when the page is full (there may be
  # more) — a short page means we hit the end → nil. created_at as ISO-8601 + message_id as text so it
  # survives the HTTP boundary and feeds straight back as an after_*/before_* cursor.
  defp next_cursor(rows, limit) when length(rows) >= limit and rows != [] do
    last = List.last(rows)
    %{created_at: DateTime.to_iso8601(last.created_at), message_id: to_string(last.message_id)}
  end

  defp next_cursor(_rows, _limit), do: nil

  defp present?(v), do: is_binary(v) and v != ""

  # Shared-media gallery: the conversation's media messages, newest first, paginated by created_at
  # cursor. A pure filtered READ of messages (no migration, nothing written); the caller's viewer
  # window (clear-chat / auto-delete) applies exactly like the timeline, and the admin path is
  # untouched (it doesn't call this).
  @impl true
  def list_media(attrs) do
    conversation_id = attr(attrs, "conversation_id")
    limit = attrs |> attr("limit") |> coerce_limit()
    viewer = attr(attrs, "viewer_user_id")
    before = attr(attrs, "before")

    rows =
      Message
      |> where([m], m.conversation_id == ^conversation_id)
      |> where([m], m.message_type == "media")
      |> where([m], is_nil(m.deleted_at))
      |> apply_viewer_window(conversation_id, viewer)
      |> maybe_before(before)
      |> order_by([m], desc: m.created_at)
      |> limit(^limit)
      |> Repo.all()

    items = Enum.map(rows, &message_response/1)
    oldest = List.last(items)

    {:ok,
     %{
       conversation_id: conversation_id,
       items: items,
       next_cursor: if(length(items) == limit, do: oldest && oldest.created_at, else: nil)
     }}
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  # The conversation a media_id was sent to (read-path authz). Takes the earliest message carrying it (a
  # media_id maps to a message); an unsent / unknown media_id → :not_found (the gateway then falls back to
  # the owner-only check). No deleted_at filter: authorization is by membership, not message liveness.
  @impl true
  def get_by_media_id(attrs) do
    case attr(attrs, "media_id") do
      media_id when is_binary(media_id) and media_id != "" ->
        Message
        |> where([m], m.media_id == ^media_id)
        |> order_by([m], asc: m.created_at)
        |> limit(1)
        |> select([m], m.conversation_id)
        |> Repo.one()
        |> case do
          nil -> {:error, :not_found}
          conversation_id -> {:ok, %{conversation_id: conversation_id}}
        end

      _ ->
        {:error, :not_found}
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  @doc """
  THE OWNER-ANCHORED DOWNLOAD RULE, one indexed EXISTS: the viewer may download iff some conversation
  they are an ACTIVE member of contains a message referencing this media_id SENT BY THE ASSET'S OWNER.
  The sender=owner anchor is what makes the widening safe — message-create does NOT validate media
  ownership, so B CAN plant a reference to A's media in B↔C; that message fails the anchor and grants
  nobody anything. The owner's own sends (broadcast fan-outs, forwards) all qualify.

  DELIBERATELY no deleted_at/liveness filter — preserving get_by_media_id's reasoning ("authorization
  is by membership, not message liveness"): a recipient doesn't lose access to bytes they legitimately
  received because the sender later deleted-for-everyone; revocation-on-delete would be a new product
  decision, not a side effect of this fix.

  Bounded: the media_id partial index (083) keys the messages side; conversation_participants' PK keys
  the membership probe. → {:ok, %{allowed: bool}}
  """
  @impl true
  def media_download_allowed(attrs) do
    with media_id when is_binary(media_id) and media_id != "" <- attr(attrs, "media_id"),
         owner when is_binary(owner) and owner != "" <- attr(attrs, "owner_user_id"),
         viewer when is_binary(viewer) and viewer != "" <- attr(attrs, "viewer_user_id") do
      %{rows: [[allowed]]} =
        Repo.query!(
          "SELECT EXISTS (" <>
            "SELECT 1 FROM messages m " <>
            "JOIN conversation_participants cp ON cp.conversation_id = m.conversation_id " <>
            "AND cp.user_id = $3::text::uuid AND cp.left_at IS NULL " <>
            "WHERE m.media_id = $1::text::uuid AND m.sender_user_id = $2::text::uuid)",
          [media_id, owner, viewer]
        )

      {:ok, %{allowed: allowed}}
    else
      # A MISSING/blank identifier is a genuine authorization miss: deny quietly, it is not a fault.
      _ -> {:ok, %{allowed: false}}
    end
  rescue
    # An exception here does NOT mean "not authorized" — it means the ORACLE ITSELF is broken (bad SQL,
    # a parameter-encoding error, the DB down). Still fail closed: a media authz oracle that answers
    # "allowed" when it cannot tell would leak media. But NEVER silently: this rescue previously turned
    # a DBConnection.EncodeError (from `$N::uuid` casts against string params) into a plain "denied",
    # so every inbound download 403'd for days with nothing in the logs. Log it loudly instead.
    error ->
      Logger.error(
        "media_download_allowed FAILED (denying, but this is a FAULT not a decision): " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      {:ok, %{allowed: false}}
  end

  defp maybe_before(query, before) when is_binary(before) and before != "" do
    case DateTime.from_iso8601(before) do
      {:ok, cutoff, _offset} -> where(query, [m], m.created_at < ^cutoff)
      _ -> query
    end
  end

  defp maybe_before(query, _), do: query

  defp coerce_limit(value) when is_integer(value), do: min(max(value, 1), 100)

  defp coerce_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, _} -> coerce_limit(n)
      :error -> 30
    end
  end

  defp coerce_limit(_), do: 30

  # USER-SCOPED soft-hide window ("clear chat" + "auto-delete") — applies ONLY when a viewer is
  # present. The admin content viewer calls list_messages WITHOUT viewer_user_id, so it can never be
  # narrowed (structural guarantee); and this is purely a read filter — no messages row is ever
  # deleted or updated by clear/auto-delete. The cutoff is the LATER of the viewer's cleared_before
  # and their rolling auto-delete window (NULL-safe: absent prefs → no narrowing).
  defp apply_viewer_window(query, _conversation_id, nil), do: query
  defp apply_viewer_window(query, _conversation_id, ""), do: query

  defp apply_viewer_window(query, conversation_id, viewer) do
    prefs = viewer_prefs(conversation_id, viewer)

    # DISAPPEARING (rolling window + after-viewing) is PERMANENT: any message that meets the disappear
    # condition NOW is materialized into user_hidden_messages (idempotent). Once a marker exists it stays,
    # so turning the setting OFF only stops hiding FUTURE messages — already-gone messages never return.
    materialize_hidden_messages(conversation_id, viewer, prefs)

    query
    # "Clear chat" stays a live cutoff (a one-way action, never toggled): hide messages at/before it.
    |> maybe_cleared_before(prefs.cleared_before)
    # Permanent per-user hidden markers: once hidden for this viewer, always hidden. Admin path (no
    # viewer) never reaches here, so admins always see every message; the messages row is never touched.
    |> where(
      [m],
      fragment(
        "NOT EXISTS (SELECT 1 FROM user_hidden_messages h WHERE h.user_id = ?::text::uuid AND h.message_id = ?)",
        ^viewer,
        m.message_id
      )
    )
  rescue
    # Malformed ids -> no narrowing (matches the permissive read path; membership is gated upstream).
    _ -> query
  end

  defp maybe_cleared_before(query, nil), do: query

  defp maybe_cleared_before(query, cleared_before),
    do: where(query, [m], m.created_at > ^cleared_before)

  # Insert permanent hidden markers for every message in this conversation that should disappear NOW for
  # the viewer under their CURRENT settings. ON CONFLICT DO NOTHING keeps it idempotent + cheap (only new
  # crossings insert). Runs only when a disappearing setting is active; best-effort (never blocks a read).
  defp materialize_hidden_messages(conversation_id, viewer, prefs) do
    if is_integer(prefs.auto_delete_seconds) and prefs.auto_delete_seconds > 0 do
      # Rolling auto-delete window: mark messages older than now() - N seconds.
      Repo.query(
        "INSERT INTO user_hidden_messages (user_id, message_id, hidden_at) " <>
          "SELECT $1::text::uuid, m.message_id, now() FROM messages m " <>
          "WHERE m.conversation_id = $2::text::uuid " <>
          "AND m.created_at <= now() - ($3 * interval '1 second') " <>
          "ON CONFLICT DO NOTHING",
        [viewer, conversation_id, prefs.auto_delete_seconds]
      )
    end

    if prefs.after_viewing_since do
      # After-viewing: mark messages created after the enable instant that the viewer has SEEN — their own
      # sent messages (authored) or a peer message they have a read receipt for.
      Repo.query(
        "INSERT INTO user_hidden_messages (user_id, message_id, hidden_at) " <>
          "SELECT $1::text::uuid, m.message_id, now() FROM messages m " <>
          "WHERE m.conversation_id = $2::text::uuid AND m.created_at > $3 " <>
          "AND (m.sender_user_id = $1::text::uuid OR EXISTS (" <>
          "  SELECT 1 FROM message_receipts r WHERE r.message_id = m.message_id " <>
          "  AND r.user_id = $1::text::uuid AND r.read_at IS NOT NULL)) " <>
          "ON CONFLICT DO NOTHING",
        [viewer, conversation_id, prefs.after_viewing_since]
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  # The viewer's soft-hide prefs (raw). cleared_before drives a live cutoff; auto_delete_seconds +
  # after_viewing_since drive permanent-marker materialization.
  defp viewer_prefs(conversation_id, viewer) do
    case Repo.query(
           "SELECT cleared_before, auto_delete_seconds, disappear_after_viewing_since " <>
             "FROM conversation_participants " <>
             "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
           [conversation_id, viewer]
         ) do
      {:ok, %{rows: [[cleared_before, auto_delete_seconds, after_viewing_since]]}} ->
        %{
          cleared_before: cleared_before,
          auto_delete_seconds: auto_delete_seconds,
          after_viewing_since: after_viewing_since
        }

      _ ->
        %{cleared_before: nil, auto_delete_seconds: nil, after_viewing_since: nil}
    end
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
  # --- Polls (079) ------------------------------------------------------------------------------

  @doc """
  Replace the caller's vote set for a poll message (ONE idempotent verb: first vote / change /
  un-vote([]) / multi-toggle). Gates: unknown / tombstoned / non-poll / wrong-conversation message →
  :message_not_found; ids outside the definition → :poll_invalid_option; >1 id on single-choice →
  :poll_single_choice. Returns the fresh aggregate — computed from poll_votes, the same source a
  history fetch reads (the broadcast is never the source of truth).
  """
  @impl true
  def poll_vote(attrs) do
    conversation_id = attr(attrs, "conversation_id")
    user_id = attr(attrs, "user_id")
    option_ids = attrs["option_ids"] || []

    with {:ok, message, definition} <- fetch_poll(attrs, conversation_id),
         :ok <- valid_vote_set(definition, option_ids) do
      {:ok, _} =
        Repo.transaction(fn ->
          Repo.query!(
            "DELETE FROM poll_votes WHERE message_id = $1::text::uuid AND user_id = $2::text::uuid",
            [message.message_id, user_id]
          )

          if option_ids != [] do
            Repo.query!(
              "INSERT INTO poll_votes (conversation_id, message_id, user_id, option_id) " <>
                "SELECT $1::text::uuid, $2::text::uuid, $3::text::uuid, unnest($4::text[])",
              [message.conversation_id, message.message_id, user_id, option_ids]
            )
          end
        end)

      {:ok, %{message_id: message.message_id, poll: poll_aggregate(message, definition)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_not_found}
  end

  @doc "The UNCAPPED per-option voter lists for one poll (the view-votes screen)."
  @impl true
  def list_poll_votes(attrs) do
    conversation_id = attr(attrs, "conversation_id")

    with {:ok, message, definition} <- fetch_poll(attrs, conversation_id) do
      {:ok,
       %{
         message_id: message.message_id,
         poll:
           MessageService.Polls.build_aggregate(
             definition,
             poll_votes_of(message.message_id),
             nil
           )
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_not_found}
  end

  # A live poll message in THIS conversation, with its definition. Everything else → :message_not_found
  # (a voter learns nothing about other conversations' messages).
  defp fetch_poll(attrs, conversation_id) do
    case fetch(attrs) do
      %Message{message_type: "poll", deleted_at: nil, conversation_id: ^conversation_id} = message ->
        case message.metadata do
          %{"poll" => %{} = definition} -> {:ok, message, definition}
          _ -> {:error, :message_not_found}
        end

      _ ->
        {:error, :message_not_found}
    end
  end

  defp valid_vote_set(definition, option_ids) do
    known = MapSet.new(definition["options"] || [], & &1["id"])

    cond do
      not Enum.all?(option_ids, &MapSet.member?(known, &1)) ->
        {:error, :poll_invalid_option}

      length(option_ids) > 1 and definition["allows_multiple"] != true ->
        {:error, :poll_single_choice}

      true ->
        :ok
    end
  end

  defp poll_votes_of(message_id) do
    PollVote
    |> where([v], v.message_id == ^message_id)
    |> order_by([v], asc: v.created_at)
    |> select([v], {v.option_id, v.user_id})
    |> Repo.all()
  end

  defp poll_aggregate(message, definition),
    do: MessageService.Polls.build_aggregate(definition, poll_votes_of(message.message_id))

  # Batched poll aggregates for a history page (the reaction_summaries twin): ONE votes query for all
  # the page's poll messages, built against each message's own stored definition. Cold loads are
  # correct by construction — this reads the same rows a vote write just committed.
  defp poll_summaries(rows) do
    poll_rows =
      Enum.filter(rows, fn m ->
        m.message_type == "poll" and is_map(m.metadata) and is_map(m.metadata["poll"])
      end)

    if poll_rows == [] do
      %{}
    else
      ids = Enum.map(poll_rows, & &1.message_id)

      votes =
        PollVote
        |> where([v], v.message_id in ^ids)
        |> order_by([v], asc: v.created_at)
        |> select([v], {v.message_id, v.option_id, v.user_id})
        |> Repo.all()
        |> Enum.group_by(fn {mid, _o, _u} -> mid end, fn {_m, o, u} -> {o, u} end)

      Map.new(poll_rows, fn m ->
        {m.message_id,
         MessageService.Polls.build_aggregate(
           m.metadata["poll"],
           Map.get(votes, m.message_id, [])
         )}
      end)
    end
  end

  defp merge_poll(response, nil), do: response
  defp merge_poll(response, aggregate), do: Map.put(response, :poll, aggregate)

  @doc """
  Message info — per-user delivery/read state for ONE message, SENDER-only (WhatsApp's Info screen).

  Gates (in order): unknown message / wrong conversation / TOMBSTONED (deleted_at set — a deleted message
  has no info screen) → :message_not_found; a non-sender viewer → :not_sender (the gateway maps 403).

  ONE receipts query regardless of member count (PK-prefix (conversation_id, message_id), ≤ member-count
  rows) with the SAME privacy join as receipt_counts. Split:
    * read      — read_at set AND the reader kept receipts on (`read_receipts_on`, the reader half) AND
                  the viewer still sees read state (`viewer_sees_read_receipts?`, the viewer half; when
                  off, read: [] + read_hidden: true — the flag means "YOUR setting hides this", not
                  "nobody read it").
    * delivered — received but not in the read list. "Received" is delivered_at OR read_at (mark_read
                  writes only read_at, so a read row without a prior delivered receipt still PROVES
                  receipt; its timestamp degrades to read_at = "received by then" — this is also where a
                  receipts-off reader lands, WhatsApp's 'stuck on Delivered').
  DEPARTED (left/removed) members' rows are kept — they genuinely received/read it while a member;
  receipts are history, not membership.
  """
  @impl true
  def message_info(attrs) do
    conversation_id = attr(attrs, "conversation_id")
    viewer = attr(attrs, "viewer_user_id")

    case fetch(attrs) do
      nil ->
        {:error, :message_not_found}

      %Message{} = message ->
        cond do
          message.conversation_id != conversation_id -> {:error, :message_not_found}
          not is_nil(message.deleted_at) -> {:error, :message_not_found}
          message.sender_user_id != viewer -> {:error, :not_sender}
          true -> {:ok, build_message_info(message, viewer)}
        end
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_not_found}
  end

  defp build_message_info(message, viewer) do
    rows =
      MessageReceipt
      |> join(:left, [r], ps in "user_privacy_settings", on: ps.user_id == r.user_id)
      |> where(
        [r],
        r.conversation_id == ^message.conversation_id and r.message_id == ^message.message_id and
          r.user_id != ^viewer
      )
      |> select([r, ps], %{
        user_id: r.user_id,
        delivered_at: r.delivered_at,
        read_at: r.read_at,
        read_visible: read_receipts_on(ps)
      })
      |> Repo.all()

    show_read = viewer_sees_read_receipts?(viewer)

    read =
      if show_read do
        rows
        |> Enum.filter(&(&1.read_at && &1.read_visible))
        |> Enum.sort_by(& &1.read_at, {:desc, DateTime})
        |> Enum.map(&%{user_id: &1.user_id, read_at: &1.read_at})
      else
        []
      end

    read_ids = MapSet.new(read, & &1.user_id)

    delivered =
      rows
      |> Enum.filter(fn row ->
        (row.delivered_at || row.read_at) && not MapSet.member?(read_ids, row.user_id)
      end)
      |> Enum.map(&%{user_id: &1.user_id, delivered_at: &1.delivered_at || &1.read_at})
      |> Enum.sort_by(& &1.delivered_at, {:desc, DateTime})

    %{
      conversation_id: message.conversation_id,
      message_id: message.message_id,
      sender_user_id: message.sender_user_id,
      read: read,
      delivered: delivered,
      read_hidden: not show_read
    }
  end

  defp receipt_counts(_conversation_id, []), do: %{}

  defp receipt_counts(conversation_id, message_ids) do
    MessageReceipt
    # LEFT JOIN the reader's privacy so read_by_count counts ONLY readers who kept read receipts ON (the
    # reader half of reciprocity, via the SHARED read_receipts_on predicate). A missing row (ps.* NULL) is
    # the default = enabled. Still ONE query for the whole page — no N+1. delivered_by_count is NOT
    # filtered (the single tick is unaffected).
    |> join(:left, [r], ps in "user_privacy_settings", on: ps.user_id == r.user_id)
    |> where([r], r.conversation_id == ^conversation_id and r.message_id in ^message_ids)
    |> group_by([r], r.message_id)
    |> select([r, ps], {
      r.message_id,
      filter(count(r.read_at), read_receipts_on(ps)),
      count(r.delivered_at)
    })
    |> Repo.all()
    |> Map.new(fn {message_id, read_by, delivered_by} ->
      {message_id, %{read_by_count: read_by, delivered_by_count: delivered_by}}
    end)
  end

  defp hide_read_count(message, true), do: message
  defp hide_read_count(message, false), do: Map.put(message, :read_by_count, 0)

  @impl true
  def update_message(attrs) do
    case fetch(attrs) do
      nil ->
        {:error, :message_not_found}

      message ->
        # Two modes: a metadata patch (e.g. live-location latest position) leaves body/status/edited_at
        # untouched; otherwise it's a body edit (marks the message "edited"). The caller has already
        # merged the patch into the full metadata map, so we just persist it.
        changes =
          case attr(attrs, "metadata") do
            metadata when is_map(metadata) ->
              %{"metadata" => metadata}

            _ ->
              %{
                "body" => attr(attrs, "body"),
                "status" => "edited",
                "edited_at" => attr(attrs, "edited_at")
              }
          end

        message
        |> Message.changeset(changes)
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            # Body edits refresh the preview iff this IS the preview; metadata patches don't touch it.
            unless is_map(attr(attrs, "metadata")),
              do: MessageService.InboxProjection.record_edit(updated)

            {:ok, message_response(updated)}

          {:error, _changeset} ->
            {:error, :message_invalid}
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
          {:ok, updated} ->
            MessageService.InboxProjection.record_delete(updated)
            {:ok, message_response(updated)}

          {:error, _changeset} ->
            {:error, :message_invalid}
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

  @doc """
  Message search — ILIKE over bodies, scoped to the caller and to what the caller can actually SEE.

  ## THIS PATH DIES WHEN DUAL-WRITE ENDS. READ THIS BEFORE TURNING DUAL-WRITE OFF.

  Under `MESSAGE_STORE_ADAPTER=scylla_read`, reads come from Scylla but WRITES ARE STILL DUAL —
  Postgres receives every message, which is what makes rollback lossless. That is the ONLY reason
  this query has bodies to search. The moment writes stop going to Postgres, `messages` decays and
  this silently returns fewer and fewer results until it returns none — a silent wrongness, not an
  error, because the query keeps succeeding.

  So whoever ends dual-write owns one of these, and must pick deliberately:

    1. ship the search index first (DECISION_LOG: it is a tsvector index derived from Scylla — and
       note that a tsvector is a lossy but READABLE copy of message content, so shipping it means
       deciding on the record that message text lives in Postgres), or
    2. re-stub search and restore the honest `search.unavailable` capability error.

  What is NOT acceptable is leaving this query pointed at a decaying table.

  ## Visibility

  A message can be alive and still invisible to a given user. Every mechanism is applied here, all
  composed from `MessageService.VisibilityWindow` so there is ONE definition of the predicate:
  participation (`left_at`), `cleared_before`, rolling `auto_delete_seconds`, permanent
  `user_hidden_messages` markers, and disappear-after-viewing evaluated inline.

  AUTHORIZATION IS A JOIN PREDICATE, NOT A POST-FILTER. Filtering after the fetch would mean reading
  rows the caller may not see (one refactor from leaking them) and would break LIMIT, since the page
  would shrink after paging. Search is the surface where a leak returns other people's messages in
  BULK, so the check is structural.
  """
  @impl true
  def search_messages(attrs) do
    user_id = attr(attrs, "user_id")
    pattern = "%" <> escape_like(attr(attrs, "query") || "") <> "%"
    {limit, offset} = page_window(attrs)

    # Raw SQL rather than Ecto: the visibility predicate is shared as SQL text with InboxProjection
    # (see VisibilityWindow for why), and a paraphrase here is exactly the drift being prevented.
    # NOTE: a leading-% ILIKE can't use a btree index -> sequential scan; acceptable at current scale,
    # and the tsvector index is the recorded upgrade.
    sql =
      "SELECT m.message_id::text, m.conversation_id::text, m.sender_user_id::text, m.message_type, " <>
        "m.body, m.media_id::text, m.metadata, m.status, m.created_at, " <>
        "m.reply_to_message_id::text, m.edited_at, m.deleted_at " <>
        "FROM messages m " <>
        "JOIN conversation_participants cp " <>
        "  ON cp.conversation_id = m.conversation_id " <>
        "  AND cp.user_id = $1::text::uuid " <>
        "  AND cp.left_at IS NULL " <>
        "WHERE m.status <> 'deleted' " <>
        "AND m.body ILIKE $2 " <>
        "AND " <> VisibilityWindow.participant_window_sql("cp", "m.created_at") <> " " <>
        "AND " <> VisibilityWindow.not_hidden_sql("m.message_id", "$1") <> " " <>
        "AND " <> VisibilityWindow.seen_under_after_viewing_sql("m", "cp", "$1") <> " " <>
        "ORDER BY m.created_at DESC LIMIT $3 OFFSET $4"

    %{rows: rows} = Repo.query!(sql, [user_id, pattern, limit, offset])

    {:ok, %{messages: Enum.map(rows, &search_row_response/1), next_cursor: nil}}
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
    Postgrex.Error -> {:error, :message_invalid}
  end

  # Raw-row -> the same response shape message_response/1 produces for an %Message{}.
  defp search_row_response([
         message_id,
         conversation_id,
         sender_user_id,
         message_type,
         body,
         media_id,
         metadata,
         status,
         created_at,
         reply_to_message_id,
         edited_at,
         deleted_at
       ]) do
    message_response(%Message{
      message_id: message_id,
      conversation_id: conversation_id,
      sender_user_id: sender_user_id,
      message_type: message_type,
      body: body,
      media_id: media_id,
      metadata: metadata,
      status: status,
      created_at: created_at,
      reply_to_message_id: reply_to_message_id,
      edited_at: edited_at,
      deleted_at: deleted_at
    })
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
      {:ok, receipt} ->
        # Inbox counter (086): a FIRST-TIME read decrements. `existing` gates idempotency — a repeat
        # read of the same message must not decrement twice, and Postgres receipts are authoritative
        # here, so the gate is exact on this path.
        if status == "read" and not already_read?(existing) do
          case fetch(attrs) do
            %Message{} = message ->
              MessageService.InboxProjection.record_read(conversation_id, user_id, message)

            _ ->
              :ok
          end
        end

        {:ok, receipt_response(receipt)}

      {:error, _changeset} ->
        {:error, :message_invalid}
    end
  rescue
    Ecto.Query.CastError -> {:error, :message_invalid}
  end

  defp already_read?(nil), do: false

  defp already_read?(%MessageReceipt{} = receipt),
    do: receipt.status == "read" or not is_nil(receipt.read_at)

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

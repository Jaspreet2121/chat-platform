defmodule MessageService.Pins do
  @moduledoc """
  PINNED MESSAGES (092) — per-conversation, up to `max_pins/0`, visible to every participant.

  Not to be confused with `conversation_participants.pinned_at` (076), which is a PER-USER inbox
  preference sorting a chat to the top of your list. Two features, one word; see the migration header.

  WHO CAN PIN is enforced at the GATEWAY, not here — it needs the caller's conversation ROLE, which
  lives in conversation_service. Same split as `only_admins_can_send`: the gateway asks
  conversation_service, then calls this. This module owns the cap, the storage and the masked read.

  ## PINS VALIDATE AND HYDRATE FROM THE MESSAGE STORE (since 2026-08-09)

  Pin ROWS stay in Postgres; the MESSAGES they point at live wherever `MessageStore` says. The
  original implementation validated and masked against the Postgres `messages` table, which froze
  at the scylla cutover — so pinning any post-cutover message failed `:message_not_found`, and the
  092 FK made it structurally impossible even with fixed validation (dropped in 095, irreversibly;
  see that migration's header). Now:

    * `ensure_live_message` is a STORE point read — with an explicit conversation check, because
      the Postgres adapter fetches by message_id alone and the cross-conversation refusal is the
      authorization-shaped clause.
    * `list_pins` reads pin rows without any messages join, HYDRATES each (≤ `max_pins` point
      reads — the `list_starred` precedent) and DRIFT-DROPS absent/tombstoned hits, so a
      pinned-then-deleted message can never render even if every unpin write was missed.
    * The per-viewer mask runs as ONE SQL over the HYDRATED values (`unnest` of message_id /
      created_at / sender_user_id) using the same `VisibilityWindow` fragments as ever — one
      definition, evaluated against store truth instead of a frozen copy.
    * A store outage returns `{:error, :message_store_unavailable}` (→ 503 `pin.unavailable` at
      the gateway), NEVER an empty list — empty asserts "no pins", which is the silent-empty class.

  The response shape is unchanged and ids-only per the contract: the client renders bodies from its
  transcript; hydration here feeds liveness and mask inputs, not the payload.
  """

  alias MessageService.Repo
  alias MessageService.VisibilityWindow

  @max_pins 3

  @doc "Pins allowed per conversation."
  def max_pins, do: @max_pins

  @doc """
  Pin a message. Idempotent — re-pinning an already-pinned message succeeds without consuming budget.

  Refuses `:pin_limit` over the cap, and `:message_not_found` when the message does not exist, is
  soft-deleted, or belongs to a DIFFERENT conversation (checked here so a caller cannot pin a message
  out of a conversation they are not in by supplying someone else's message id).
  """
  def pin_message(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, message_id} <- required(attrs, "message_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         :ok <- ensure_live_message(conversation_id, message_id),
         :ok <- ensure_under_cap(conversation_id, message_id) do
      Repo.query!(
        "INSERT INTO message_pins (conversation_id, message_id, pinned_by) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid) " <>
          "ON CONFLICT (conversation_id, message_id) DO NOTHING",
        [conversation_id, message_id, user_id]
      )

      {:ok, %{conversation_id: conversation_id, message_id: message_id, pinned: true}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :pin_invalid}
  end

  @doc "Unpin. Idempotent — unpinning something not pinned succeeds."
  def unpin_message(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, message_id} <- required(attrs, "message_id") do
      Repo.query!(
        "DELETE FROM message_pins " <>
          "WHERE conversation_id = $1::text::uuid AND message_id = $2::text::uuid",
        [conversation_id, message_id]
      )

      {:ok, %{conversation_id: conversation_id, message_id: message_id, pinned: false}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :pin_invalid}
  end

  @doc """
  The pins a given VIEWER may see, newest pin first.

  ## THE PINNED SET IS GLOBAL; THIS LIST IS MASKED PER USER

  TWO PEOPLE IN THE SAME GROUP CAN LEGITIMATELY SEE DIFFERENT PINNED BARS. That is not a bug.

  IF YOU REMOVE THE MASK BELOW YOU WILL RESURRECT MESSAGES THIS USER CLEARED, OR THAT AUTO-DELETED FOR
  THEM, OR THAT THEY DELETED FOR THEMSELVES — showing them the text of a message they cannot open.
  A pin is per-conversation; `cleared_before`, the rolling `auto_delete_seconds` window and
  `user_hidden_messages` are all per-user, and a pin overrides none of them.

  This exact mistake already shipped once: message search returned hits for cleared and auto-deleted
  messages for its whole life before it was fixed. The predicate is composed from
  `MessageService.VisibilityWindow` so it has one definition, not a paraphrase.

  A soft-deleted message is filtered here too — the unpin-on-delete write path keeps the cap honest,
  and this filter is what makes a missed write path unable to resurrect a tombstone.
  """
  def list_pins(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id") do
      viewer = get(attrs, "user_id")

      %{rows: rows} =
        Repo.query!(
          "SELECT p.message_id::text, p.pinned_by::text, p.pinned_at " <>
            "FROM message_pins p WHERE p.conversation_id = $1::text::uuid " <>
            "ORDER BY p.pinned_at DESC",
          [conversation_id]
        )

      with {:ok, live} <- hydrate_pins(conversation_id, rows),
           {:ok, visible} <- mask_pins(conversation_id, viewer, live) do
        {:ok,
         %{
           pins:
             Enum.map(visible, fn {[message_id, pinned_by, pinned_at], _message} ->
               %{message_id: message_id, pinned_by: pinned_by, pinned_at: pinned_at}
             end)
         }}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :pin_invalid}
  end

  # Hydrate each pin from the STORE (≤ max_pins point reads — the list_starred precedent).
  # DRIFT-DROP is the deletion net: an absent or tombstoned hit is dropped, so a pinned-then-deleted
  # message never renders even when every unpin write was missed. A store OUTAGE is different in
  # kind and aborts the list — an empty bar asserting "no pins" during an outage is the
  # silent-empty class this codebase keeps paying for.
  defp hydrate_pins(conversation_id, rows) do
    Enum.reduce_while(rows, {:ok, []}, fn [message_id, _, _] = row, {:ok, acc} ->
      case MessageService.MessageStore.get_message(%{
             "conversation_id" => conversation_id,
             "message_id" => message_id
           }) do
        {:ok, message} ->
          if message_deleted?(message),
            do: {:cont, {:ok, acc}},
            else: {:cont, {:ok, [{row, message} | acc]}}

        {:error, :message_store_unavailable} ->
          {:halt, {:error, :message_store_unavailable}}

        _ ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      other -> other
    end
  end

  # THE MASK, same three VisibilityWindow fragments as ever — ONE definition — evaluated against the
  # HYDRATED store values via unnest, because the per-message inputs (created_at, sender_user_id) no
  # longer live in any Postgres table. No viewer (admin/system read) → no per-user narrowing,
  # exactly as before; the drift-drop above still applies.
  defp mask_pins(_conversation_id, viewer, live) when not is_binary(viewer) or viewer == "",
    do: {:ok, live}

  defp mask_pins(_conversation_id, _viewer, []), do: {:ok, []}

  defp mask_pins(conversation_id, viewer, live) do
    {ids, created_ats, senders} =
      live
      |> Enum.map(fn {[message_id, _, _], message} ->
        {message_id, store_get(message, :created_at),
         to_string(store_get(message, :sender_user_id))}
      end)
      |> Enum.reduce({[], [], []}, fn {i, c, s}, {is, cs, ss} ->
        {[i | is], [c | cs], [s | ss]}
      end)

    sql =
      "SELECT v.message_id::text " <>
        "FROM unnest($2::text[]::uuid[], $3::timestamptz[], $4::text[]::uuid[]) " <>
        "AS v(message_id, created_at, sender_user_id) " <>
        "JOIN conversation_participants cp " <>
        "  ON cp.conversation_id = $1::text::uuid " <>
        "  AND cp.user_id = $5::text::uuid " <>
        "  AND cp.left_at IS NULL " <>
        "WHERE " <>
        VisibilityWindow.participant_window_sql("cp", "v.created_at") <>
        " " <>
        "AND " <>
        VisibilityWindow.not_hidden_sql("v.message_id", "$5") <>
        " " <>
        "AND " <>
        VisibilityWindow.seen_under_after_viewing_sql("v", "cp", "$5")

    %{rows: visible_rows} = Repo.query!(sql, [conversation_id, ids, created_ats, senders, viewer])
    visible = MapSet.new(visible_rows, fn [id] -> id end)

    {:ok,
     Enum.filter(live, fn {[message_id, _, _], _} -> MapSet.member?(visible, message_id) end)}
  end

  @doc """
  Drop a message's pin — called from the delete path so a deleted message stops occupying pin budget.

  The read filter is the safety net; this is what keeps the CAP honest. Best-effort by design: a
  failure here must never fail the delete, because the read filter already prevents the tombstone
  being shown.
  """
  def unpin_deleted(message_id) when is_binary(message_id) and message_id != "" do
    Repo.query!("DELETE FROM message_pins WHERE message_id = $1::text::uuid", [message_id])
    :ok
  rescue
    _ -> :ok
  end

  def unpin_deleted(_message_id), do: :ok

  # --- guards -------------------------------------------------------------------------------------

  # The message must exist, be live, and belong to THIS conversation. The conversation check is the
  # authorization-shaped one: without it a caller could pin a message from a conversation they are
  # not in — and it must be EXPLICIT here because the Postgres adapter fetches by message_id alone
  # (the Scylla adapter is (conversation, message)-keyed and refuses naturally).
  defp ensure_live_message(conversation_id, message_id) do
    case MessageService.MessageStore.get_message(%{
           "conversation_id" => conversation_id,
           "message_id" => message_id
         }) do
      {:ok, message} ->
        cond do
          message_deleted?(message) ->
            {:error, :message_not_found}

          to_string(store_get(message, :conversation_id)) != conversation_id ->
            {:error, :message_not_found}

          true ->
            :ok
        end

      {:error, :message_store_unavailable} ->
        # The store being down is not "message not found" — that would lie a 404 for an outage.
        # Crosses the seam as :message_unavailable → 503 pin.unavailable at the gateway.
        {:error, :message_store_unavailable}

      _ ->
        {:error, :message_not_found}
    end
  end

  defp message_deleted?(message) do
    store_get(message, :status) == "deleted" or not is_nil(store_get(message, :deleted_at))
  end

  defp store_get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # Re-pinning something already pinned must NOT count against the cap (the insert is a no-op), so the
  # cap check excludes the target row.
  defp ensure_under_cap(conversation_id, message_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM message_pins " <>
          "WHERE conversation_id = $1::text::uuid AND message_id <> $2::text::uuid",
        [conversation_id, message_id]
      )

    if count >= @max_pins, do: {:error, :pin_limit}, else: :ok
  end

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :pin_invalid}
    end
  end

  defp get(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, safe_atom(key))

  defp get(_attrs, _key), do: nil

  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing__
  end
end

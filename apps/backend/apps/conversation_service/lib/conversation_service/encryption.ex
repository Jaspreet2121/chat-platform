defmodule ConversationService.Encryption do
  @moduledoc """
  Secret-chat control plane (108; two-party OFF in 118).

  ON is what 108 shipped: either participant, immediate, both members holding a live device key
  (107) — without that a sealed message would be unreadable on arrival. OFF is TWO-PARTY: one member
  REQUESTS, the OTHER member's own OFF is the ACCEPTANCE, and only that second call flips `secret`.
  A single-sided OFF never changes the flag — the recorded v1 reason still stands (a one-way
  downgrade is a content-exposure attack surface); what 118 adds is that both parties consenting is
  not one-way. A pending request expires after 7 days (treated as absent, cleared on read), is
  cancellable by its requester only, and is invalidated by either side turning ON again. An
  accepted OFF stamps `e2ee_disabled_at` — the explicit "turned off" marker the client-side
  opportunistic upgrade (109 §9 ii) must respect; the next ON clears it.

  Every decision runs under `SELECT ... FOR UPDATE` on the conversation row, so two concurrent OFFs
  can neither both record a request nor both accept. Preconditions are enforced HERE at the store:
  direct only, caller is an active member (unknown id and non-member are ONE answer — no existence
  reveal), and for ON both members have keys.
  """

  alias ConversationService.Repo

  @off_request_ttl_seconds 7 * 24 * 60 * 60

  @doc "The pending-OFF window in seconds: a request older than this is absent."
  def off_request_ttl_seconds, do: @off_request_ttl_seconds

  @doc """
  attrs: "conversation_id", "user_id" (the SESSION user, never payload identity), "enabled"
  (boolean), "cancel" (optional boolean, read only with enabled: false).

    enabled: true             ON — either participant, immediate. Clears e2ee_disabled_at AND any
                              pending OFF request. change: "enabled" on a real flip; "off_cancelled"
                              when already secret and a request was pending; nil when nothing moved.
    enabled: false            OFF — no pending request: RECORD one by the caller ("off_requested");
                              pending from the OTHER member: ACCEPT — flip to plain, stamp
                              e2ee_disabled_at, clear the request ("disabled"); pending from the
                              CALLER: idempotent (nil); already plain: idempotent (nil).
    enabled: false, cancel    the requester clears their own pending request ("off_cancelled"); the
                              other member → :secret_not_requester; nothing pending → idempotent.

  → {:ok, %{enabled, already, change, member_ids, e2ee_disabled, off_pending}} — `off_pending` is
  %{requested_by, requested_at (ISO-8601)} or nil; `member_ids` so the gateway can broadcast + write
  the system message. Errors: :secret_not_supported (group), :conversation_not_found (unknown /
  caller not a member), :secret_not_requester, :secret_invalid (malformed body),
  {:secret_peer_keys_missing, [user_ids]} (ON only), :conversation_invalid (malformed ids).
  """
  def set_encryption(attrs) do
    with {:ok, conversation_id} <- uuid(attrs, "conversation_id"),
         {:ok, user_id} <- uuid(attrs, "user_id"),
         {:ok, action} <- action(attrs) do
      Repo.transaction(fn -> decide(action, conversation_id, user_id) end)
    end
  end

  @doc """
  The detail response's view of 118 for one conversation: %{e2ee_disabled, off_pending}. A pending
  request past its window is reported ABSENT and cleaned up here, best-effort — the clear is
  conditional on the stale timestamp, so a fresh request landing in between is never clobbered.
  """
  def off_state(conversation_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT e2ee_disabled_at, e2ee_off_requested_by::text, e2ee_off_requested_at " <>
          "FROM conversations WHERE id = $1::text::uuid",
        [conversation_id]
      )

    case rows do
      [[disabled_at, requested_by, requested_at] | _] ->
        pending =
          cond do
            is_nil(requested_by) ->
              nil

            fresh_request?(requested_at) ->
              %{requested_by: requested_by, requested_at: DateTime.to_iso8601(requested_at)}

            true ->
              clear_stale_request(conversation_id)
              nil
          end

        %{e2ee_disabled: not is_nil(disabled_at), off_pending: pending}

      [] ->
        %{e2ee_disabled: false, off_pending: nil}
    end
  end

  @doc "The ids of every SECRET conversation `user_id` actively belongs to (the keys_changed fan-out)."
  def secret_conversations_of(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id") do
      %{rows: rows} =
        Repo.query!(
          "SELECT c.id::text FROM conversations c " <>
            "JOIN conversation_participants p ON p.conversation_id = c.id " <>
            "AND p.user_id = $1::text::uuid AND p.left_at IS NULL " <>
            "WHERE c.secret AND c.status = 'active'",
          [user_id]
        )

      {:ok, %{conversation_ids: Enum.map(rows, fn [id] -> id end)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
  end

  @doc """
  The 107-key precondition for a member set, shared with conversation CREATE ("secret": true):
  the user ids among `member_ids` that have NO device key on a live (non-revoked) device.
  """
  def members_without_keys(member_ids) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT (m.id)::text FROM unnest($1::text[]) AS t(id), LATERAL (SELECT (t.id)::uuid AS id) m
        WHERE NOT EXISTS (
          SELECT 1 FROM device_keys k
          JOIN device_sessions ds ON ds.user_id = k.user_id AND ds.device_id = k.device_id
            AND ds.revoked_at IS NULL
          WHERE k.user_id = m.id
        )
        """,
        [member_ids]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  # --- the decision, under the row lock ------------------------------------------------------------

  defp decide(action, conversation_id, user_id) do
    case lock_conversation(conversation_id, user_id) do
      nil ->
        # Unknown id and not-a-member are the same answer — no existence reveal.
        Repo.rollback(:conversation_not_found)

      %{type: type} when type != "direct" ->
        Repo.rollback(:secret_not_supported)

      row ->
        members = member_ids(conversation_id)

        case apply_action(action, expire_stale_request(row, members), members, user_id) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp lock_conversation(conversation_id, user_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT c.type, c.secret, c.e2ee_disabled_at, c.e2ee_off_requested_by::text, " <>
          "c.e2ee_off_requested_at FROM conversations c " <>
          "JOIN conversation_participants p ON p.conversation_id = c.id " <>
          "AND p.user_id = $2::text::uuid AND p.left_at IS NULL " <>
          "WHERE c.id = $1::text::uuid AND c.status = 'active' FOR UPDATE OF c",
        [conversation_id, user_id]
      )

    case rows do
      [[type, secret, disabled_at, requested_by, requested_at] | _] ->
        %{
          id: conversation_id,
          type: type,
          secret: secret == true,
          disabled_at: disabled_at,
          requested_by: requested_by,
          requested_at: requested_at
        }

      [] ->
        nil
    end
  end

  # A request is honoured only inside its window and only while its requester is still a member;
  # anything else is absent — and cleared, so the row never carries a dead request forward.
  defp expire_stale_request(%{requested_by: nil} = row, _members), do: row

  defp expire_stale_request(row, members) do
    if fresh_request?(row.requested_at) and row.requested_by in members do
      row
    else
      clear_request(row.id)
      %{row | requested_by: nil, requested_at: nil}
    end
  end

  # ON — either participant, immediate.
  defp apply_action(:enable, %{secret: true, requested_by: nil} = row, members, _user_id),
    do: {:ok, result(row, members, already: true, change: nil)}

  defp apply_action(:enable, %{secret: true} = row, members, _user_id) do
    # Already secret with a pending OFF: turning ON again INVALIDATES the request.
    clear_request(row.id)

    {:ok,
     result(%{row | requested_by: nil, requested_at: nil}, members,
       already: true,
       change: "off_cancelled"
     )}
  end

  defp apply_action(:enable, row, members, _user_id) do
    case members_without_keys(members) do
      [] ->
        Repo.query!(
          "UPDATE conversations SET secret = true, e2ee_disabled_at = NULL, " <>
            "e2ee_off_requested_by = NULL, e2ee_off_requested_at = NULL, updated_at = now() " <>
            "WHERE id = $1::text::uuid",
          [row.id]
        )

        {:ok,
         result(
           %{row | secret: true, disabled_at: nil, requested_by: nil, requested_at: nil},
           members,
           already: false,
           change: "enabled"
         )}

      missing ->
        {:error, {:secret_peer_keys_missing, missing}}
    end
  end

  # OFF — two-party. Already plain: nothing to request.
  defp apply_action(:request_off, %{secret: false} = row, members, _user_id),
    do: {:ok, result(row, members, already: true, change: nil)}

  defp apply_action(:request_off, %{requested_by: nil} = row, members, user_id) do
    %{rows: [[requested_at]]} =
      Repo.query!(
        "UPDATE conversations SET e2ee_off_requested_by = $2::text::uuid, " <>
          "e2ee_off_requested_at = now(), updated_at = now() " <>
          "WHERE id = $1::text::uuid RETURNING e2ee_off_requested_at",
        [row.id, user_id]
      )

    {:ok,
     result(%{row | requested_by: user_id, requested_at: requested_at}, members,
       already: false,
       change: "off_requested"
     )}
  end

  # The requester asking again: the SAME request, never a second one and never an acceptance.
  defp apply_action(:request_off, %{requested_by: user_id} = row, members, user_id),
    do: {:ok, result(row, members, already: true, change: nil)}

  defp apply_action(:request_off, row, members, _user_id) do
    # The OTHER member's own OFF is the acceptance — the only statement that ever flips `secret`
    # to false, and it stamps the explicit-off marker in the same write.
    %{rows: [[disabled_at]]} =
      Repo.query!(
        "UPDATE conversations SET secret = false, e2ee_disabled_at = now(), " <>
          "e2ee_off_requested_by = NULL, e2ee_off_requested_at = NULL, updated_at = now() " <>
          "WHERE id = $1::text::uuid RETURNING e2ee_disabled_at",
        [row.id]
      )

    {:ok,
     result(
       %{row | secret: false, disabled_at: disabled_at, requested_by: nil, requested_at: nil},
       members,
       already: false,
       change: "disabled"
     )}
  end

  # CANCEL — the requester only.
  defp apply_action(:cancel, %{requested_by: nil} = row, members, _user_id),
    do: {:ok, result(row, members, already: true, change: nil)}

  defp apply_action(:cancel, %{requested_by: user_id} = row, members, user_id) do
    clear_request(row.id)

    {:ok,
     result(%{row | requested_by: nil, requested_at: nil}, members,
       already: false,
       change: "off_cancelled"
     )}
  end

  defp apply_action(:cancel, _row, _members, _user_id), do: {:error, :secret_not_requester}

  defp result(row, members, opts) do
    %{
      enabled: row.secret,
      already: Keyword.fetch!(opts, :already),
      change: Keyword.fetch!(opts, :change),
      member_ids: members,
      e2ee_disabled: not is_nil(row.disabled_at),
      off_pending: pending(row)
    }
  end

  defp pending(%{requested_by: requested_by, requested_at: %DateTime{} = requested_at})
       when is_binary(requested_by),
       do: %{requested_by: requested_by, requested_at: DateTime.to_iso8601(requested_at)}

  defp pending(_row), do: nil

  defp fresh_request?(%DateTime{} = requested_at),
    do: DateTime.diff(DateTime.utc_now(), requested_at, :second) < @off_request_ttl_seconds

  defp fresh_request?(_), do: false

  defp clear_request(conversation_id) do
    Repo.query!(
      "UPDATE conversations SET e2ee_off_requested_by = NULL, e2ee_off_requested_at = NULL, " <>
        "updated_at = now() WHERE id = $1::text::uuid",
      [conversation_id]
    )

    :ok
  end

  # The unlocked (read-path) clear: only a request that IS stale goes, by its own timestamp.
  defp clear_stale_request(conversation_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@off_request_ttl_seconds, :second)

    Repo.query!(
      "UPDATE conversations SET e2ee_off_requested_by = NULL, e2ee_off_requested_at = NULL " <>
        "WHERE id = $1::text::uuid AND e2ee_off_requested_at IS NOT NULL " <>
        "AND e2ee_off_requested_at <= $2",
      [conversation_id, cutoff]
    )

    :ok
  end

  defp action(attrs) do
    case {Map.get(attrs, "enabled"), Map.get(attrs, "cancel")} do
      {true, _cancel} -> {:ok, :enable}
      {false, true} -> {:ok, :cancel}
      {false, cancel} when cancel in [nil, false] -> {:ok, :request_off}
      _ -> {:error, :secret_invalid}
    end
  end

  defp member_ids(conversation_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT user_id::text FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND left_at IS NULL ORDER BY joined_at",
        [conversation_id]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  # Ids are cast BEFORE any raw `::uuid` cast can raise mid-transaction.
  defp uuid(attrs, key) do
    with {:ok, value} <- required(attrs, key),
         {:ok, _uuid} <- Ecto.UUID.cast(value) do
      {:ok, value}
    else
      _ -> {:error, :conversation_invalid}
    end
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :conversation_invalid}
    end
  end
end

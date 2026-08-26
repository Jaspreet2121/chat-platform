defmodule ConversationService.Encryption do
  @moduledoc """
  Secret-chat control plane (108). Enabling E2EE on a 1:1 is ONE-WAY in v1 — disable is refused
  (recorded decision: a downgrade toggle is a content-exposure attack surface; a user who wants out
  starts a new normal chat). Preconditions are enforced HERE at the store: direct only, caller is
  an active member, and BOTH members have at least one registered device key on a live device
  (the 107 registry) — without that, a sealed message would be unreadable on arrival.
  """

  alias ConversationService.Repo

  @doc """
  Enable E2EE on a direct conversation. → {:ok, %{enabled: true, member_ids: [a, b]}} (member_ids so
  the gateway can broadcast + write the system message). Errors:
  :secret_not_supported (group), :conversation_not_found (unknown / caller not a member),
  :secret_cannot_disable (enabled: false — one-way), {:secret_peer_keys_missing, [user_ids]}.
  Re-enabling an already-secret conversation is idempotent.
  """
  def set_encryption(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, user_id} <- required(attrs, "user_id"),
         true <- Map.get(attrs, "enabled") == true || {:error, :secret_cannot_disable} do
      %{rows: rows} =
        Repo.query!(
          "SELECT c.type, c.secret FROM conversations c " <>
            "JOIN conversation_participants p ON p.conversation_id = c.id " <>
            "AND p.user_id = $2::text::uuid AND p.left_at IS NULL " <>
            "WHERE c.id = $1::text::uuid AND c.status = 'active'",
          [conversation_id, user_id]
        )

      case rows do
        [] ->
          # Unknown id and not-a-member are the same answer — no existence reveal.
          {:error, :conversation_not_found}

        [[type, _secret]] when type != "direct" ->
          {:error, :secret_not_supported}

        [[_type, true]] ->
          {:ok, %{enabled: true, member_ids: member_ids(conversation_id), already: true}}

        [[_type, _]] ->
          members = member_ids(conversation_id)

          case members_without_keys(members) do
            [] ->
              Repo.query!(
                "UPDATE conversations SET secret = true, updated_at = now() WHERE id = $1::text::uuid",
                [conversation_id]
              )

              {:ok, %{enabled: true, member_ids: members, already: false}}

            missing ->
              {:error, {:secret_peer_keys_missing, missing}}
          end
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :conversation_invalid}
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

  defp member_ids(conversation_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT user_id::text FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND left_at IS NULL ORDER BY joined_at",
        [conversation_id]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :conversation_invalid}
    end
  end
end

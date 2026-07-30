defmodule ConversationService.InviteLinks do
  @moduledoc """
  Group invite links (077) — the domain logic behind the shareable, WhatsApp-style "join a group via link".

  Management (create / revoke / reset) is OWNER-ONLY, matching this codebase's decision that member-adding
  is owner-controlled (`add_participant` is owner-only): an admin-mintable link would hand admins an
  indirect member-add they don't have directly. One ACTIVE link per conversation (the store's partial
  unique index); create is idempotent, reset = revoke + mint.

  JOIN goes through the SAME participant insert + `participant_added` event an owner add fires, so the inbox
  row, unread, and `conversation_updated` fan-out are identical (the gateway fires the `:participant` frame
  after this returns). Cases (left rows keyed by `left_reason`, 078):
    * already an active member → idempotent, no duplicate row, no broadcast;
    * `left_reason='removed'` → the link REFUSES them (`:removed`); the owner's removal stands (an owner
      re-ADD does readmit them — that's the owner deliberately overriding their own removal);
    * `left_reason='left'` (voluntary leave) → REACTIVATED as a fresh member (role member, joined_at
      reset — roles aren't retained across membership), same event as a fresh join;
    * no row → fresh join (role member).

  App-scoped: a code only resolves within its conversation's tenant (a cross-tenant code → not found).
  """

  alias ConversationService.ConversationStore
  alias ConversationService.InviteLinkStore
  alias ConversationService.ParticipantEvents
  alias ConversationService.ParticipantStore
  alias ConversationService.Schemas.GroupInviteLink

  # --- Management (owner-only) --------------------------------------------------------------------

  @doc "Mint or return the conversation's single active link. Owner-only. → {:ok, %{code, conversation_id}}."
  def create_link(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, actor_user_id} <- required(attrs, "actor_user_id"),
         :ok <- ensure_persistence(),
         {:ok, conversation} <- fetch_active_group(conversation_id),
         :ok <- require_owner(conversation_id, actor_user_id) do
      case InviteLinkStore.get_active_by_conversation(conversation_id) do
        %GroupInviteLink{code: code} ->
          {:ok, link_result(code, conversation_id)}

        nil ->
          with {:ok, link} <-
                 InviteLinkStore.create(conversation_id, conversation.app_id, actor_user_id) do
            {:ok, link_result(link.code, conversation_id)}
          end
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :invalid_request}
  end

  @doc "Revoke the conversation's active link (immediate; idempotent). Owner-only. → {:ok, %{revoked: true}}."
  def revoke_link(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, actor_user_id} <- required(attrs, "actor_user_id"),
         :ok <- ensure_persistence(),
         {:ok, _conversation} <- fetch_active_group(conversation_id),
         :ok <- require_owner(conversation_id, actor_user_id),
         {:ok, _count} <- InviteLinkStore.revoke_active(conversation_id) do
      {:ok, %{revoked: true}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :invalid_request}
  end

  @doc "Reset = revoke the active link + mint a new one, in one action. Owner-only. → {:ok, %{code, ...}}."
  def reset_link(attrs) do
    with {:ok, conversation_id} <- required(attrs, "conversation_id"),
         {:ok, actor_user_id} <- required(attrs, "actor_user_id"),
         :ok <- ensure_persistence(),
         {:ok, conversation} <- fetch_active_group(conversation_id),
         :ok <- require_owner(conversation_id, actor_user_id),
         {:ok, _count} <- InviteLinkStore.revoke_active(conversation_id),
         {:ok, link} <- InviteLinkStore.create(conversation_id, conversation.app_id, actor_user_id) do
      {:ok, link_result(link.code, conversation_id)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :invalid_request}
  end

  # --- Code-scoped (preview / join) --------------------------------------------------------------

  @doc "Join-preview metadata for a code (app-scoped). → {:ok, %{name, group_avatar_media_id, member_count}}."
  def preview_link(attrs) do
    with {:ok, code} <- required(attrs, "code"),
         {:ok, app_id} <- required(attrs, "app_id"),
         :ok <- ensure_persistence(),
         %GroupInviteLink{conversation_id: conversation_id} <-
           InviteLinkStore.get_active_by_code(code, app_id),
         preview when is_map(preview) <- InviteLinkStore.group_preview(conversation_id) do
      {:ok, preview}
    else
      nil -> {:error, :link_not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :link_not_found}
  end

  @doc """
  Join via a code (app-scoped). → {:ok, %{status: "joined"|"already_member", conversation_id, role}} or
  {:error, :removed} (a removed user) / {:error, :link_not_found}.
  """
  def join_link(attrs) do
    with {:ok, code} <- required(attrs, "code"),
         {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         :ok <- ensure_persistence(),
         %GroupInviteLink{conversation_id: conversation_id} <-
           InviteLinkStore.get_active_by_code(code, app_id),
         {:ok, _conversation} <- fetch_active_group(conversation_id) do
      seat_joiner(conversation_id, user_id)
    else
      nil -> {:error, :link_not_found}
      # A dead / non-group conversation behind a live code → 404 like any unknown code.
      {:error, :not_a_group} -> {:error, :link_not_found}
      {:error, :conversation_not_found} -> {:error, :link_not_found}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :link_not_found}
  end

  # Seat the joiner against their existing participant row (if any). Left rows split on left_reason
  # (078): 'removed' → refused (the owner's removal stands); 'left' → reactivated as a fresh member.
  defp seat_joiner(conversation_id, user_id) do
    case ParticipantStore.get_participant(conversation_id, user_id) do
      %{left_at: nil, role: role} ->
        {:ok, %{status: "already_member", conversation_id: conversation_id, role: role}}

      %{left_at: left_at, left_reason: "left"} = participant when not is_nil(left_at) ->
        rejoin_member(conversation_id, user_id, participant)

      %{left_at: left_at} when not is_nil(left_at) ->
        {:error, :removed}

      nil ->
        add_member(conversation_id, user_id)
    end
  end

  # A voluntary leaver rejoining via a live link: reactivate their row as a fresh MEMBER (role/joined_at
  # reset — roles aren't retained across membership) + the same participant_added event a fresh join fires.
  defp rejoin_member(conversation_id, user_id, participant) do
    case ParticipantStore.reactivate_participant(participant, %{
           "role" => "member",
           "joined_at" => now()
         }) do
      {:ok, _reactivated} ->
        ParticipantEvents.publish_participant_added(%{
          conversation_id: conversation_id,
          user_id: user_id,
          role: "member",
          added_by: user_id
        })

        {:ok, %{status: "joined", conversation_id: conversation_id, role: "member"}}

      {:error, _changeset} ->
        {:error, :join_failed}
    end
  end

  # The SAME store insert + event an owner add fires — identical downstream state (the gateway then fires
  # the :participant broadcast, exactly as the add-participant controller does).
  defp add_member(conversation_id, user_id) do
    case ParticipantStore.add_participant(%{
           "conversation_id" => conversation_id,
           "user_id" => user_id,
           "role" => "member",
           "joined_at" => now()
         }) do
      {:ok, _participant} ->
        ParticipantEvents.publish_participant_added(%{
          conversation_id: conversation_id,
          user_id: user_id,
          role: "member",
          added_by: user_id
        })

        {:ok, %{status: "joined", conversation_id: conversation_id, role: "member"}}

      {:error, _changeset} ->
        {:error, :join_failed}
    end
  end

  # --- helpers -----------------------------------------------------------------------------------

  defp fetch_active_group(conversation_id) do
    case ConversationStore.get_conversation(conversation_id) do
      %{status: "active", type: "group"} = conversation -> {:ok, conversation}
      %{} -> {:error, :not_a_group}
      nil -> {:error, :conversation_not_found}
    end
  end

  # Owner-only (§1): a link is a member-adding mechanism, and member-adding is owner-controlled here.
  defp require_owner(conversation_id, actor_user_id) do
    case ParticipantStore.get_participant(conversation_id, actor_user_id) do
      %{left_at: nil, role: "owner"} -> :ok
      _ -> {:error, :not_owner}
    end
  end

  defp link_result(code, conversation_id), do: %{code: code, conversation_id: conversation_id}

  defp ensure_persistence do
    if conversation_persistence_enabled?(), do: :ok, else: {:error, :conversation_unavailable}
  end

  defp required(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :invalid_request}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp conversation_persistence_enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end
end

defmodule ConversationService.InviteLinkStore do
  @moduledoc """
  DB access for `group_invite_links` (077). Mint (retry on a code collision), resolve the ACTIVE link by
  code (app-scoped) or by conversation, revoke, and read a group's join-preview metadata. All lookups are
  scoped to ACTIVE rows so a revoked code is invisible (a join with it 404s like an unknown code).
  """

  import Ecto.Query, only: [from: 2]

  alias ConversationService.Repo
  alias ConversationService.Schemas.GroupInviteLink

  # 16 random bytes → 128 bits, ~22 url-safe chars. Possessing the code grants group access, so a wide
  # margin (2^128) is worth 11 chars over the call-link generator's 8 bytes. Never sequential / derived.
  @code_bytes 16
  @mint_attempts 5

  @doc "Mint a fresh active link, retrying on the astronomically-unlikely code collision."
  def create(conversation_id, app_id, created_by),
    do: create(conversation_id, app_id, created_by, @mint_attempts)

  defp create(_conversation_id, _app_id, _created_by, 0), do: {:error, :link_collision}

  defp create(conversation_id, app_id, created_by, attempts) do
    %{
      code: generate_code(),
      conversation_id: conversation_id,
      app_id: app_id,
      created_by: created_by,
      active: true,
      created_at: DateTime.utc_now()
    }
    |> GroupInviteLink.create_changeset()
    |> Repo.insert()
    |> case do
      {:ok, link} ->
        {:ok, link}

      {:error, changeset} ->
        # A conversation-index conflict means another mint won the race → return THAT active link (idempotent
        # create). A pure code (pkey) collision → retry with a new code.
        case get_active_by_conversation(conversation_id) do
          %GroupInviteLink{} = existing -> {:ok, existing}
          nil -> retry_or_fail(changeset, conversation_id, app_id, created_by, attempts)
        end
    end
  end

  defp retry_or_fail(_changeset, conversation_id, app_id, created_by, attempts),
    do: create(conversation_id, app_id, created_by, attempts - 1)

  # The active link for a code, scoped to the caller's tenant — a cross-tenant code is invisible (nil → 404).
  def get_active_by_code(code, app_id) when is_binary(code) and is_binary(app_id) do
    Repo.one(
      from(l in GroupInviteLink,
        where: l.code == ^code and l.active == true and l.app_id == ^app_id,
        limit: 1
      )
    )
  end

  def get_active_by_code(_code, _app_id), do: nil

  # The (single) active link for a conversation — backed by the partial unique index.
  def get_active_by_conversation(conversation_id) do
    Repo.one(
      from(l in GroupInviteLink,
        where: l.conversation_id == ^conversation_id and l.active == true,
        limit: 1
      )
    )
  end

  @doc "Revoke the active link for a conversation (idempotent — no active link → 0 rows, still :ok)."
  def revoke_active(conversation_id) do
    {count, _} =
      Repo.update_all(
        from(l in GroupInviteLink,
          where: l.conversation_id == ^conversation_id and l.active == true
        ),
        set: [active: false]
      )

    {:ok, count}
  end

  @doc """
  Join-preview metadata for a group: name (COALESCE(group_profiles.name, conversations.title) — the SAME
  resolution the inbox/detail use), avatar media id, and the ACTIVE member count. Returns nil for a
  non-group / non-active conversation.
  """
  def group_preview(conversation_id) do
    result =
      Repo.query!(
        """
        SELECT COALESCE(gp.name, c.title),
               gp.avatar_media_id::text,
               (SELECT count(*) FROM conversation_participants p
                  WHERE p.conversation_id = c.id AND p.left_at IS NULL)
          FROM conversations c
          LEFT JOIN group_profiles gp ON gp.conversation_id = c.id
         WHERE c.id = $1::text::uuid AND c.type = 'group' AND c.status = 'active'
        """,
        [conversation_id]
      )

    case result.rows do
      [[name, avatar_media_id, member_count]] ->
        %{name: name, group_avatar_media_id: avatar_media_id, member_count: member_count}

      _ ->
        nil
    end
  end

  defp generate_code,
    do: :crypto.strong_rand_bytes(@code_bytes) |> Base.url_encode64(padding: false)
end

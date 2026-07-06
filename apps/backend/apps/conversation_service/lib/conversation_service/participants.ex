defmodule ConversationService.Participants do
  @moduledoc """
  Conversation participant boundary.
  """

  alias ConversationService.ConversationSettingsStore
  alias ConversationService.ConversationStore
  alias ConversationService.ParticipantEvents
  alias ConversationService.ParticipantStore
  alias ConversationService.Repo

  @type participant_attrs :: map()
  @type result :: {:ok, map()} | {:error, atom()}

  @callback add_participant(participant_attrs()) :: result()
  @callback remove_participant(participant_attrs()) :: result()

  def add_participant(attrs) do
    if conversation_persistence_enabled?() do
      add_participant_in_db(attrs)
    else
      placeholder_add_participant(attrs)
    end
  end

  def remove_participant(attrs) do
    if conversation_persistence_enabled?() do
      remove_participant_in_db(attrs)
    else
      placeholder_remove_participant(attrs)
    end
  end

  # --- Group admin (roles / only-admins-send) -----------------------------------------------------

  @doc """
  OWNER-only: promote a member → admin or demote an admin → member. Rejects setting/clearing "owner",
  targeting the owner, or an invalid role. Only the owner manages who is an admin.
  """
  def set_participant_role(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, target_user_id} <- required_attr(attrs, "user_id"),
         {:ok, actor_user_id} <- required_attr(attrs, "actor_user_id"),
         {:ok, role} <- validate_settable_role(attrs["role"]) do
      if conversation_persistence_enabled?() do
        with {:ok, _conversation} <- fetch_active_conversation(conversation_id),
             {:ok, _actor} <- require_owner(conversation_id, actor_user_id),
             {:ok, target} <- fetch_active_participant(conversation_id, target_user_id),
             :ok <- ensure_not_owner_target(target),
             %Postgrex.Result{num_rows: 1} <-
               Repo.query!(
                 "UPDATE conversation_participants SET role = $3 " <>
                   "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid AND left_at IS NULL",
                 [conversation_id, target_user_id, role]
               ) do
          {:ok, %{conversation_id: conversation_id, user_id: target_user_id, role: role}}
        else
          {:error, reason} -> {:error, reason}
          _ -> {:error, :participant_invalid}
        end
      else
        {:ok, %{conversation_id: conversation_id, user_id: target_user_id, role: role}}
      end
    end
  rescue
    _ -> {:error, :participant_invalid}
  end

  @doc """
  Owner OR admin: toggle group settings (currently only_admins_can_send). Upserts the settings row.
  """
  def set_group_settings(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, actor_user_id} <- required_attr(attrs, "actor_user_id"),
         {:ok, only_admins} <- boolean_attr(attrs, "only_admins_can_send"),
         {:ok, call_permission} <- call_permission_attr(attrs) do
      if conversation_persistence_enabled?() do
        with {:ok, _conversation} <- fetch_active_conversation(conversation_id),
             {:ok, _actor} <- require_owner_or_admin(conversation_id, actor_user_id),
             {:ok, _settings} <- upsert_settings(conversation_id, only_admins, call_permission) do
          {:ok, settings_result(conversation_id, only_admins, call_permission)}
        end
      else
        {:ok, settings_result(conversation_id, only_admins, call_permission)}
      end
    end
  rescue
    _ -> {:error, :participant_invalid}
  end

  @doc """
  SEND authorization for the enforced only-admins-can-send mode. :ok unless the conversation is a group
  with only_admins_can_send = true AND the sender's role is "member" (or not an active participant).
  Non-groups / flag off → always :ok. Called by BOTH the REST and realtime send paths.
  """
  def authorize_send(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, user_id} <- required_attr(attrs, "user_id") do
      if conversation_persistence_enabled?() do
        case fetch_active_conversation(conversation_id) do
          {:ok, %{type: "group"}} ->
            if only_admins_can_send?(conversation_id) do
              case fetch_active_participant(conversation_id, user_id) do
                {:ok, %{role: role}} when role in ["owner", "admin"] -> {:ok, %{authorized: true}}
                _ -> {:error, :only_admins_can_send}
              end
            else
              {:ok, %{authorized: true}}
            end

          _ ->
            {:ok, %{authorized: true}}
        end
      else
        {:ok, %{authorized: true}}
      end
    end
  rescue
    # Fail OPEN on a malformed id / transient error — never block a legitimate send on a check glitch.
    _ -> {:ok, %{authorized: true}}
  end

  defp validate_settable_role(role) when role in ["admin", "member"], do: {:ok, role}
  defp validate_settable_role(_), do: {:error, :invalid_request}

  defp ensure_not_owner_target(%{role: "owner"}), do: {:error, :participant_forbidden}
  defp ensure_not_owner_target(_), do: :ok

  defp boolean_attr(attrs, key) do
    case Map.get(attrs, key) do
      v when v in [true, "true", "1", "yes"] -> {:ok, true}
      v when v in [false, "false", "0", "no", nil] -> {:ok, false}
      _ -> {:error, :invalid_request}
    end
  end

  # Optional call_start_permission ("everyone"|"admins_only"); nil = not provided → don't change it.
  defp call_permission_attr(attrs) do
    case Map.get(attrs, "call_start_permission") do
      v when v in ["everyone", "admins_only"] -> {:ok, v}
      nil -> {:ok, nil}
      _ -> {:error, :invalid_request}
    end
  end

  defp settings_result(conversation_id, only_admins, call_permission) do
    base = %{conversation_id: conversation_id, only_admins_can_send: only_admins}
    if is_nil(call_permission), do: base, else: Map.put(base, :call_start_permission, call_permission)
  end

  defp upsert_settings(conversation_id, only_admins, call_permission) do
    patch =
      %{"only_admins_can_send" => only_admins}
      |> maybe_put("call_start_permission", call_permission)

    case ConversationSettingsStore.get_settings(conversation_id) do
      nil ->
        ConversationSettingsStore.create_settings(Map.put(patch, "conversation_id", conversation_id))

      settings ->
        ConversationSettingsStore.update_settings(settings, patch)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp only_admins_can_send?(conversation_id) do
    case ConversationSettingsStore.get_settings(conversation_id) do
      %{only_admins_can_send: true} -> true
      _ -> false
    end
  end

  # --- User-scoped view prefs (soft-hides; write ONLY the caller's own participant row) -----------
  # "Clear chat": stamp cleared_before = now() on the CALLER's active membership row. Purely a read
  # marker for that user's message fetches — no messages row is touched, admin reads are unaffected.
  def clear_history(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, user_id} <- required_attr(attrs, "user_id") do
      if conversation_persistence_enabled?() do
        update_own_participant(
          "cleared_before = now()",
          conversation_id,
          user_id,
          fn -> %{conversation_id: conversation_id, user_id: user_id, cleared: true} end
        )
      else
        {:ok, %{conversation_id: conversation_id, user_id: user_id, cleared: true}}
      end
    end
  end

  # "Disappearing messages" modes → {auto_delete_seconds, disappear_after_viewing}. All soft-hides:
  #   off           → no window
  #   after_viewing → hide messages this user has already read (message_receipts.read_at)
  #   8h/24h/7d     → rolling created_at window
  @disappear_modes %{
    "off" => {nil, false},
    "after_viewing" => {nil, true},
    "8h" => {28_800, false},
    "24h" => {86_400, false},
    "7d" => {604_800, false}
  }

  # "Disappearing messages" (extends the old auto-delete): set the rolling window / after-viewing flag.
  # SCOPE: "mine" (default) writes only the CALLER's row (their own view narrows); "both" writes EVERY
  # active participant's row so it hides from everyone's view. Both are SOFT-HIDE — nothing is deleted
  # and the admin path (no viewer_user_id) is never filtered. Any active participant may set either scope.
  def set_auto_delete(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, user_id} <- required_attr(attrs, "user_id"),
         {:ok, {seconds, after_viewing?}} <- disappear_setting(attrs) do
      scope = disappear_scope(attrs)

      response = %{
        conversation_id: conversation_id,
        user_id: user_id,
        auto_delete_seconds: seconds,
        after_viewing: after_viewing?,
        scope: scope
      }

      if conversation_persistence_enabled?() do
        seconds_clause =
          if is_nil(seconds), do: "auto_delete_seconds = NULL", else: "auto_delete_seconds = #{seconds}"

        # seconds is a fixed integer or NULL and after_viewing? is a boolean — both compile-side
        # constants from the mode map, never interpolated user input. Enabling "after viewing" stamps
        # disappear_after_viewing_since = now() so the filter only hides messages sent AFTER this point
        # (old history stays); disabling clears it.
        after_viewing_clause =
          if after_viewing?,
            do: "disappear_after_viewing = true, disappear_after_viewing_since = now()",
            else: "disappear_after_viewing = false, disappear_after_viewing_since = NULL"

        set_clause = seconds_clause <> ", " <> after_viewing_clause

        case scope do
          "both" -> update_all_participants(set_clause, conversation_id, user_id, fn -> response end)
          _ -> update_own_participant(set_clause, conversation_id, user_id, fn -> response end)
        end
      else
        {:ok, response}
      end
    end
  end

  defp disappear_scope(attrs) do
    if to_string(attrs["scope"]) == "both", do: "both", else: "mine"
  end

  # Mute modes → the `muted_until` SET clause. "always" = 'infinity' (never < now()); off = NULL.
  @mute_clauses %{
    "off" => "muted_until = NULL",
    "8h" => "muted_until = now() + interval '8 hours'",
    "1w" => "muted_until = now() + interval '7 days'",
    "always" => "muted_until = 'infinity'"
  }

  # "Mute notifications": set the CALLER's muted_until on their own participant row. Suppresses
  # WEB-PUSH for this conversation while muted (PushSender skips muted recipients). Read marker only —
  # nothing else changes; clauses come ONLY from the fixed map (no user input interpolated).
  def set_mute(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, user_id} <- required_attr(attrs, "user_id"),
         {:ok, set_clause} <- mute_clause(attrs) do
      if conversation_persistence_enabled?() do
        update_own_participant(set_clause, conversation_id, user_id, fn ->
          %{conversation_id: conversation_id, user_id: user_id, mode: attrs["mode"]}
        end)
      else
        {:ok, %{conversation_id: conversation_id, user_id: user_id, mode: attrs["mode"]}}
      end
    end
  end

  defp mute_clause(attrs) do
    case Map.fetch(@mute_clauses, to_string(attrs["mode"])) do
      {:ok, clause} -> {:ok, clause}
      :error -> {:error, :invalid_request}
    end
  end

  # {seconds, after_viewing?} comes ONLY from the fixed mode map (never interpolated user input).
  defp disappear_setting(attrs) do
    case Map.fetch(@disappear_modes, to_string(attrs["mode"])) do
      {:ok, setting} -> {:ok, setting}
      :error -> {:error, :invalid_request}
    end
  end

  # Guarded single-row UPDATE: the WHERE pins it to the caller's own ACTIVE membership, so a
  # non-member (or someone who left) updates 0 rows → forbidden. set_clause is a compile-side
  # constant (now()/NULL/mode-mapped integer) — no user input is interpolated.
  defp update_own_participant(set_clause, conversation_id, user_id, ok_response) do
    case ConversationService.Repo.query(
           "UPDATE conversation_participants SET #{set_clause} " <>
             "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid AND left_at IS NULL",
           [conversation_id, user_id]
         ) do
      {:ok, %{num_rows: 1}} -> {:ok, ok_response.()}
      {:ok, _} -> {:error, :not_participant}
      {:error, _} -> {:error, :conversation_invalid}
    end
  rescue
    _ -> {:error, :conversation_invalid}
  end

  # "Both sides" scope: apply the window to EVERY active participant's row so messages disappear from
  # everyone's own view. Guarded — the caller must be an active participant first (else forbidden). Still
  # a soft-hide (no messages deleted; admin path unfiltered). set_clause is a compile-side constant.
  defp update_all_participants(set_clause, conversation_id, user_id, ok_response) do
    with {:ok, %{num_rows: 1}} <-
           ConversationService.Repo.query(
             "SELECT 1 FROM conversation_participants " <>
               "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid AND left_at IS NULL",
             [conversation_id, user_id]
           ),
         {:ok, _} <-
           ConversationService.Repo.query(
             "UPDATE conversation_participants SET #{set_clause} " <>
               "WHERE conversation_id = $1::text::uuid AND left_at IS NULL",
             [conversation_id]
           ) do
      {:ok, ok_response.()}
    else
      {:ok, %{num_rows: 0}} -> {:error, :not_participant}
      _ -> {:error, :conversation_invalid}
    end
  rescue
    _ -> {:error, :conversation_invalid}
  end

  def placeholder_participants do
    [
      %{
        user_id: "user_123",
        role: "member",
        joined_at: "2026-06-17T10:00:00Z"
      }
    ]
  end

  defp add_participant_in_db(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, target_user_id} <- required_attr(attrs, "user_id"),
         {:ok, actor_user_id} <- required_attr(attrs, "actor_user_id"),
         {:ok, role} <- participant_role(attrs),
         {:ok, _conversation} <- fetch_active_conversation(conversation_id),
         {:ok, _actor_participant} <- require_owner(conversation_id, actor_user_id),
         :ok <- ensure_not_active_participant(conversation_id, target_user_id),
         {:ok, participant} <-
           ParticipantStore.add_participant(%{
             "conversation_id" => conversation_id,
             "user_id" => target_user_id,
             "role" => role,
             "joined_at" => now()
           }) do
      # After a successful persist, emit participant_added (fire-and-forget).
      ParticipantEvents.publish_participant_added(%{
        conversation_id: conversation_id,
        user_id: target_user_id,
        role: role,
        added_by: actor_user_id
      })

      {:ok, participant_response(participant)}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :participant_invalid}
  end

  defp remove_participant_in_db(attrs) do
    with {:ok, conversation_id} <- required_attr(attrs, "conversation_id"),
         {:ok, target_user_id} <- required_attr(attrs, "user_id"),
         {:ok, actor_user_id} <- required_attr(attrs, "actor_user_id"),
         {:ok, _conversation} <- fetch_active_conversation(conversation_id),
         {:ok, actor_participant} <- require_owner_or_admin(conversation_id, actor_user_id),
         {:ok, target_participant} <- fetch_active_participant(conversation_id, target_user_id),
         :ok <- ensure_not_owner(target_participant),
         # An ADMIN may remove members only (not the owner — covered above — nor another admin). The
         # OWNER may remove anyone. Enforced server-side; a member never reaches here (gate above).
         :ok <- ensure_can_remove(actor_participant, target_participant),
         {:ok, removed_participant} <-
           ParticipantStore.remove_participant(target_participant, %{
             "left_at" => now()
           }) do
      # After a successful persist, emit participant_removed (fire-and-forget).
      ParticipantEvents.publish_participant_removed(%{
        conversation_id: conversation_id,
        user_id: target_user_id,
        removed_by: actor_user_id
      })

      {:ok,
       %{
         conversation_id: removed_participant.conversation_id,
         user_id: removed_participant.user_id,
         removed: true,
         left_at: iso8601(removed_participant.left_at)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.Query.CastError -> {:error, :participant_invalid}
  end

  defp fetch_active_conversation(conversation_id) do
    case ConversationStore.get_conversation(conversation_id) do
      nil -> {:error, :conversation_not_found}
      %{status: "active"} = conversation -> {:ok, conversation}
      _conversation -> {:error, :conversation_not_found}
    end
  end

  defp require_owner(conversation_id, actor_user_id) do
    with {:ok, participant} <- fetch_active_participant(conversation_id, actor_user_id) do
      if participant.role == "owner" do
        {:ok, participant}
      else
        {:error, :participant_forbidden}
      end
    end
  end

  defp require_owner_or_admin(conversation_id, actor_user_id) do
    with {:ok, participant} <- fetch_active_participant(conversation_id, actor_user_id) do
      if participant.role in ["owner", "admin"] do
        {:ok, participant}
      else
        {:error, :participant_forbidden}
      end
    end
  end

  # Owner removes anyone (owner-self already blocked upstream). Admin removes MEMBERS only.
  defp ensure_can_remove(%{role: "owner"}, _target), do: :ok
  defp ensure_can_remove(%{role: "admin"}, %{role: "member"}), do: :ok
  defp ensure_can_remove(_actor, _target), do: {:error, :participant_forbidden}

  defp fetch_active_participant(conversation_id, user_id) do
    case ParticipantStore.get_participant(conversation_id, user_id) do
      nil -> {:error, :participant_not_found}
      %{left_at: nil} = participant -> {:ok, participant}
      _participant -> {:error, :participant_not_found}
    end
  end

  defp ensure_not_active_participant(conversation_id, user_id) do
    case ParticipantStore.get_participant(conversation_id, user_id) do
      nil -> :ok
      %{left_at: nil} -> {:error, :participant_already_exists}
      _left_participant -> {:error, :participant_already_exists}
    end
  end

  defp ensure_not_owner(%{role: "owner"}), do: {:error, :participant_owner_remove_forbidden}
  defp ensure_not_owner(_participant), do: :ok

  defp participant_role(attrs) do
    role = get_attr(attrs, "role") || "member"

    if role in ["member", "admin"] do
      {:ok, role}
    else
      {:error, :participant_invalid}
    end
  end

  defp participant_response(participant) do
    %{
      conversation_id: participant.conversation_id,
      user_id: participant.user_id,
      role: participant.role,
      joined_at: iso8601(participant.joined_at)
    }
  end

  defp placeholder_add_participant(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       user_id: Map.get(attrs, "user_id", "user_placeholder"),
       role: Map.get(attrs, "role", "member"),
       joined_at: "2026-06-17T10:00:00Z"
     }}
  end

  defp placeholder_remove_participant(attrs) do
    {:ok,
     %{
       conversation_id: Map.get(attrs, "conversation_id", "conv_placeholder"),
       user_id: Map.get(attrs, "user_id", "user_placeholder"),
       removed: true
     }}
  end

  defp required_attr(attrs, key) do
    case get_attr(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :participant_invalid}
    end
  end

  defp get_attr(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp conversation_persistence_enabled? do
    Application.get_env(:conversation_service, :conversation_persistence, false) ||
      System.get_env("CONVERSATION_DB_BACKED") in ["true", "1", "yes"]
  end
end

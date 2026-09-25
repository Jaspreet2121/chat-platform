defmodule ConversationService.AdminPeerLabelTest do
  @moduledoc """
  A direct chat's label in the content viewer is the peer's NAME, else their handle, else "(no
  name)" — never their phone number. The subquery that builds `other_name` used to fall back to
  `users_auth.phone_number`, which put a bare phone in the title of every chat with a user who had
  not set a display name: exactly the leak the console's naming rule exists to stop.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.Conversations

  @tenant "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp user!(phone, opts \\ []) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active')",
      [id, @tenant, phone]
    )

    if Keyword.has_key?(opts, :username) or Keyword.has_key?(opts, :display_name) do
      username = Keyword.get(opts, :username)

      Repo.query!(
        "INSERT INTO user_profiles (user_id, app_id, display_name, username, username_key) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3, $4, lower($4))",
        [id, @tenant, Keyword.get(opts, :display_name), username]
      )
    end

    id
  end

  defp direct!(a, b) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'direct', $3::text::uuid)",
      [id, @tenant, a]
    )

    for u <- [a, b] do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, u]
      )
    end

    id
  end

  defp label_for(me) do
    {:ok, %{conversations: [row]}} =
      Conversations.admin_user_conversations(%{"user_id" => me, "app_id" => @tenant})

    row.other_name
  end

  @tag :postgres_integration
  test "name, else @handle, else (no name) — and NEVER the phone" do
    me = user!("+15550100001")

    named = user!("+15550100002", display_name: "Guru", username: "guru")
    handle_only = user!("+15550100003", username: "quiet")
    nothing = user!("+15550100004")

    direct!(me, named)
    assert label_for(me) == "Guru"

    Repo.query!("DELETE FROM conversations", [])
    direct!(me, handle_only)
    assert label_for(me) == "@quiet"

    Repo.query!("DELETE FROM conversations", [])
    direct!(me, nothing)
    label = label_for(me)
    assert label == "(no name)"
    refute label =~ "0100004"
  end
end

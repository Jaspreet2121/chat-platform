defmodule ConversationService.PeersOfTest do
  @moduledoc """
  The recipient set for a profile change — every user who shares an ACTIVE conversation with the
  actor, on real SQL.

  It decides who is told that someone's avatar changed, so the two ways to get it wrong are both
  pinned: too NARROW leaves a peer drawing a stale picture for an hour, and too WIDE leaks "this
  account exists and I have something to tell you about it" to a stranger. Self, people who have
  left, and archived/inactive conversations are all outside the set — and a user who shares two
  conversations with the actor appears once, not twice.
  """
  use ExUnit.Case, async: false

  alias ConversationService.Conversations
  alias ConversationService.Repo

  @tag :postgres_integration
  test "everyone sharing a DM or a group, DISTINCT, never the actor" do
    a = user!()
    dm_peer = user!()
    group_peer = user!()
    stranger = user!()

    direct!(a, dm_peer)
    group!(a, [group_peer])
    # A SECOND shared conversation with the same peer — the set is people, not memberships.
    group!(a, [dm_peer])
    # A conversation the actor is not in at all.
    direct!(group_peer, stranger)

    assert {:ok, %{user_ids: ids}} = Conversations.peers_of(%{"user_id" => a})

    assert Enum.sort(ids) == Enum.sort([dm_peer, group_peer]),
           "the fan-out set is wrong: #{inspect(ids)}"

    refute a in ids,
           "the actor is in their own recipient set — the change would echo to the " <>
             "device that just made it"

    refute stranger in ids, "a user who shares no conversation was told about this account"
  end

  @tag :postgres_integration
  test "a member who LEFT is no longer a peer, and neither is the actor after they leave" do
    a = user!()
    stayed = user!()
    left = user!()

    group = group!(a, [stayed, left])

    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [group, left]
    )

    assert {:ok, %{user_ids: ids}} = Conversations.peers_of(%{"user_id" => a})
    assert ids == [stayed]

    # ...and once the ACTOR leaves, that conversation stops feeding their set entirely.
    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [group, a]
    )

    assert {:ok, %{user_ids: []}} = Conversations.peers_of(%{"user_id" => a})
  end

  @tag :postgres_integration
  test "an INACTIVE conversation contributes nobody" do
    a = user!()
    peer = user!()
    conversation = direct!(a, peer)

    Repo.query!("UPDATE conversations SET status = 'archived' WHERE id = $1::text::uuid", [
      conversation
    ])

    assert {:ok, %{user_ids: []}} = Conversations.peers_of(%{"user_id" => a})
  end

  @tag :postgres_integration
  test "a user with no conversations gets an empty list, not an error" do
    assert {:ok, %{user_ids: []}} = Conversations.peers_of(%{"user_id" => user!()})
  end

  @tag :postgres_integration
  test "a missing or malformed user_id is refused, never a full-table answer" do
    assert {:error, _} = Conversations.peers_of(%{})
    assert {:error, :conversation_invalid} = Conversations.peers_of(%{"user_id" => "not-a-uuid"})
  end

  # --- helpers --------------------------------------------------------------------------------------

  defp direct!(a, b) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        "type" => "direct",
        "created_by" => a,
        "participant_user_ids" => [b]
      })

    conv.conversation_id
  end

  defp group!(owner, members) do
    {:ok, conv} =
      Conversations.create_conversation(%{
        "type" => "group",
        "title" => "Peers",
        "created_by" => owner,
        "participant_user_ids" => members
      })

    conv.conversation_id
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, phone_number, status) VALUES ($1::text::uuid, $2, 'active')",
      [id, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    start_repo!(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp start_repo!(repo) do
    case repo.start_link() do
      {:ok, pid} -> Process.unlink(pid) && :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end

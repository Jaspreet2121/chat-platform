defmodule ConversationService.BestFriendTest do
  @moduledoc """
  The best-friend pin (125): at most ONE per user, only on a DM the user is actually in, and
  `mutual` true only when BOTH active members have pinned each other. The member list the write
  returns is what the gateway broadcasts to — so this suite also pins the fact that it contains
  exactly the DM's members and nobody else (MUT-4's server half).
  """
  use ExUnit.Case, async: false

  alias ConversationService.Conversations
  alias ConversationService.Participants
  alias ConversationService.Repo

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    case Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, status) VALUES ($1::text::uuid, $2, 'active')",
      [id, "bf-#{System.unique_integer([:positive])}@example.test"]
    )

    id
  end

  defp dm!(a, b) do
    {:ok, conversation} =
      Conversations.create_conversation(%{
        "type" => "direct",
        "created_by" => a,
        "participant_user_ids" => [b]
      })

    conversation.conversation_id
  end

  defp pin(user_id, conversation_id) do
    Participants.set_best_friend(%{"user_id" => user_id, "conversation_id" => conversation_id})
  end

  defp pinned_count(user_id) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM conversation_participants " <>
          "WHERE user_id = $1::text::uuid AND best_friend_at IS NOT NULL",
        [user_id]
      )

    count
  end

  @tag :postgres_integration
  test "one side pinning is NOT mutual; the other pinning back makes it mutual for both" do
    a = user!()
    b = user!()
    dm = dm!(a, b)

    assert {:ok, first} = pin(a, dm)
    assert first.best_friend == true
    assert first.mutual == false
    assert Enum.sort(first.member_ids) == Enum.sort([a, b])

    assert {:ok, second} = pin(b, dm)
    assert second.mutual == true
    assert Enum.sort(second.member_ids) == Enum.sort([a, b])

    # Re-pinning the same chat is idempotent, not a second pin.
    assert {:ok, again} = pin(a, dm)
    assert again.mutual == true
    assert pinned_count(a) == 1
  end

  @tag :postgres_integration
  test "AT MOST ONE per user: pinning a second DM clears the first" do
    a = user!()
    b = user!()
    c = user!()
    first = dm!(a, b)
    second = dm!(a, c)

    assert {:ok, _} = pin(a, first)
    assert {:ok, _} = pin(a, second)

    assert pinned_count(a) == 1

    %{rows: [[still]]} =
      Repo.query!(
        "SELECT conversation_id::text FROM conversation_participants " <>
          "WHERE user_id = $1::text::uuid AND best_friend_at IS NOT NULL",
        [a]
      )

    assert still == second
  end

  @tag :postgres_integration
  test "clearing returns the conversation that WAS pinned, so the mutual:false frame has a topic" do
    a = user!()
    b = user!()
    dm = dm!(a, b)

    assert {:ok, _} = pin(a, dm)
    assert {:ok, _} = pin(b, dm)

    assert {:ok, cleared} =
             Participants.set_best_friend(%{"user_id" => a, "conversation_id" => nil})

    assert cleared.conversation_id == dm
    assert cleared.best_friend == false
    assert cleared.mutual == false
    assert Enum.sort(cleared.member_ids) == Enum.sort([a, b])
    assert pinned_count(a) == 0

    # b's own pin is untouched — one user clearing does not unpin the other.
    assert pinned_count(b) == 1
  end

  @tag :postgres_integration
  test "MUT-4 guard (server half): a NON-MEMBER cannot pin, so they can never be in a member list" do
    a = user!()
    b = user!()
    outsider = user!()
    dm = dm!(a, b)

    assert {:error, :conversation_membership_forbidden} = pin(outsider, dm)
    assert pinned_count(outsider) == 0

    assert {:ok, result} = pin(a, dm)
    refute outsider in result.member_ids
  end

  @tag :postgres_integration
  test "a GROUP is refused — there is no pair to be mutual with" do
    a = user!()
    b = user!()
    c = user!()

    {:ok, group} =
      Conversations.create_conversation(%{
        "type" => "group",
        "title" => "Squad",
        "created_by" => a,
        "participant_user_ids" => [b, c]
      })

    assert {:error, :best_friend_direct_only} = pin(a, group.conversation_id)
    assert pinned_count(a) == 0
  end

  @tag :postgres_integration
  test "the INBOX ROW carries streak_days and the caller's OWN best_friend flag — never the other side's" do
    a = user!()
    b = user!()
    dm = dm!(a, b)

    # A counted day, written the way the message service writes it.
    Repo.query!(
      "INSERT INTO dm_streaks (conversation_id, streak_days, last_both_sides_date) " <>
        "VALUES ($1::text::uuid, 5, CURRENT_DATE)",
      [dm]
    )

    assert {:ok, _} = pin(a, dm)

    {:ok, %{rows: rows}} =
      Conversations.inbox_rows(%{"user_ids" => [a, b], "conversation_id" => dm})

    by_user = Map.new(rows, &{&1.user_id, &1})

    assert by_user[a].streak_days == 5
    assert by_user[b].streak_days == 5

    # The PIN is per-user: a sees their own, b sees false — b learns nothing about a's choice from
    # the list (that is what best_friend_mutual is for, and only once it is returned).
    assert by_user[a].best_friend == true
    assert by_user[b].best_friend == false
  end

  @tag :postgres_integration
  test "a GROUP row reports streak_days 0 — the key is always present, the value is never invented" do
    a = user!()
    b = user!()

    {:ok, group} =
      Conversations.create_conversation(%{
        "type" => "group",
        "title" => "Squad",
        "created_by" => a,
        "participant_user_ids" => [b]
      })

    {:ok, %{rows: rows}} =
      Conversations.inbox_rows(%{
        "user_ids" => [a],
        "conversation_id" => group.conversation_id
      })

    row = Enum.find(rows, &(&1.conversation_id == group.conversation_id))

    assert row.streak_days == 0
    assert row.best_friend == false
  end

  @tag :postgres_integration
  test "a member who LEFT is not counted, so a departed pin cannot hold the pair mutual" do
    a = user!()
    b = user!()
    dm = dm!(a, b)

    assert {:ok, _} = pin(a, dm)
    assert {:ok, both} = pin(b, dm)
    assert both.mutual == true

    Repo.query!(
      "UPDATE conversation_participants SET left_at = now() " <>
        "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
      [dm, b]
    )

    assert {:ok, after_leave} = pin(a, dm)
    assert after_leave.mutual == false
    assert after_leave.member_ids == [a]
  end
end

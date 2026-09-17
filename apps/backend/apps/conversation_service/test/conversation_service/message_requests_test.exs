defmodule ConversationService.MessageRequestsTest do
  @moduledoc """
  MESSAGE REQUESTS (128) — the stamp, the three inbox scopes, accept, decline, and the audience rule.
  `@tag :postgres_integration` throughout: every one of these is a SQL predicate, and a stubbed
  version would prove nothing about the thing that actually decides.

  The mutation guards these carry:

    * MUT-2 an unaccepted request appears in the main inbox → RED
    * MUT-3 a declined sender can still send (no block written) → RED
    * MUT-6 a pending row counts as a shared conversation → RED
    * MUT-8 the row key set differs between a pending and an accepted row → RED
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.{Conversations, MessageRequests}

  @app_id "00000000-0000-0000-0000-000000000001"

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp user!(name) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{name}-#{id}@test.local"]
    )

    id
  end

  # The REAL creation path, so the stamp is exercised where it actually runs.
  defp create_direct!(creator, peer) do
    {:ok, response} =
      Conversations.create_conversation(%{
        "type" => "direct",
        "created_by" => creator,
        "participant_user_ids" => [creator, peer]
      })

    Map.get(response, :conversation_id) || Map.get(response, "conversation_id")
  end

  defp pending_at(conversation_id, user_id) do
    %Postgrex.Result{rows: [[at]]} =
      Repo.query!(
        "SELECT request_pending_at FROM conversation_participants " <>
          "WHERE conversation_id = $1::text::uuid AND user_id = $2::text::uuid",
        [conversation_id, user_id]
      )

    at
  end

  defp inbox(user_id, params \\ %{}) do
    {:ok, %{conversations: rows}} =
      Conversations.list_conversations(Map.merge(%{"user_id" => user_id}, params))

    rows
  end

  defp ids(rows), do: Enum.map(rows, & &1.conversation_id)

  describe "the stamp" do
    @tag :postgres_integration
    test "a first DM between strangers stamps the RECIPIENT only" do
      sender = user!("sender")
      recipient = user!("recipient")
      conversation = create_direct!(sender, recipient)

      assert %DateTime{} = pending_at(conversation, recipient)
      refute pending_at(conversation, sender)
    end

    @tag :postgres_integration
    test "a prior shared conversation means they are not strangers — no stamp" do
      a = user!("a")
      b = user!("b")
      _first = create_direct!(a, b)

      # A second direct conversation between the same pair would normally be deduped; a GROUP is the
      # honest way to have a second, and it is also the case the rule has to cover.
      group = Ecto.UUID.generate()

      Repo.query!(
        "INSERT INTO conversations (id, type, title, created_by, status, created_at, updated_at) " <>
          "VALUES ($1::text::uuid, 'group', 'g', $2::text::uuid, 'active', now(), now())",
        [group, a]
      )

      for u <- [a, b] do
        Repo.query!(
          "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
            "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
          [group, u]
        )
      end

      c = user!("c")

      # a and c share the group? No — c is not in it. Use b, who now shares an ACCEPTED group with a.
      Repo.query!(
        "UPDATE conversation_participants SET request_pending_at = NULL " <>
          "WHERE conversation_id = $1::text::uuid",
        [group]
      )

      refute MessageRequests.stranger?(a, b, Ecto.UUID.generate())
      assert MessageRequests.stranger?(a, c, Ecto.UUID.generate())
    end

    @tag :postgres_integration
    test "a nearby connection or a dating match means they are not strangers" do
      a = user!("near-a")
      b = user!("near-b")
      c = user!("date-a")
      d = user!("date-b")

      {low, high} = if a < b, do: {a, b}, else: {b, a}

      Repo.query!(
        "INSERT INTO nearby_connections (app_id, user_low_id, user_high_id) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid)",
        [@app_id, low, high]
      )

      {dlow, dhigh} = if c < d, do: {c, d}, else: {d, c}

      Repo.query!(
        "INSERT INTO dating_matches (app_id, user_low_id, user_high_id) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid)",
        [@app_id, dlow, dhigh]
      )

      refute MessageRequests.stranger?(a, b, Ecto.UUID.generate())
      refute MessageRequests.stranger?(c, d, Ecto.UUID.generate())
      assert MessageRequests.stranger?(a, c, Ecto.UUID.generate())
    end

    @tag :postgres_integration
    test "a PENDING row is not itself a connection — a second stranger pair still reads as strangers" do
      sender = user!("s")
      recipient = user!("r")
      conversation = create_direct!(sender, recipient)

      assert pending_at(conversation, recipient)
      # The very conversation that is pending must not make them known to each other.
      assert MessageRequests.stranger?(sender, recipient, Ecto.UUID.generate())
    end
  end

  describe "the inbox scopes" do
    setup do
      sender = user!("s")
      recipient = user!("r")
      conversation = create_direct!(sender, recipient)
      {:ok, sender: sender, recipient: recipient, conversation: conversation}
    end

    @tag :postgres_integration
    test "MUT-2 guard: the default list EXCLUDES the request; ?scope=requests shows only it",
         %{recipient: recipient, conversation: conversation} do
      refute conversation in ids(inbox(recipient))
      assert [conversation] == ids(inbox(recipient, %{"scope" => "requests"}))
      assert [] == ids(inbox(recipient, %{"archived" => "true"}))
    end

    @tag :postgres_integration
    test "the SENDER's own side is a normal conversation from the start",
         %{sender: sender, conversation: conversation} do
      assert conversation in ids(inbox(sender))
      assert [] == ids(inbox(sender, %{"scope" => "requests"}))
    end

    @tag :postgres_integration
    test "MUT-8 guard: a pending row and an accepted row have the IDENTICAL key set",
         %{recipient: recipient, conversation: conversation} do
      [pending_row] = inbox(recipient, %{"scope" => "requests"})
      assert pending_row.request_pending == true

      assert {:ok, _} =
               MessageRequests.accept(%{
                 "conversation_id" => conversation,
                 "user_id" => recipient
               })

      [accepted_row] = inbox(recipient)
      assert accepted_row.request_pending == false

      assert Map.keys(pending_row) |> Enum.sort() == Map.keys(accepted_row) |> Enum.sort()

      assert Map.keys(accepted_row) |> Enum.sort() == [
               :archived,
               :best_friend,
               :conversation_id,
               :group_avatar_media_id,
               :last_message_kind,
               :last_message_preview,
               :pinned,
               :request_pending,
               :streak_days,
               :tag_ids,
               :title,
               :type,
               :unread_count,
               :updated_at
             ]
    end

    @tag :postgres_integration
    test "the broadcast query ('any') carries a PENDING row, so a client's flags update live",
         %{recipient: recipient, conversation: conversation} do
      {:ok, %{rows: rows}} =
        Conversations.inbox_rows(%{
          "conversation_id" => conversation,
          "user_ids" => [recipient]
        })

      assert [row] = rows
      assert row.request_pending == true
    end
  end

  describe "accept and decline" do
    setup do
      sender = user!("s")
      recipient = user!("r")
      conversation = create_direct!(sender, recipient)
      {:ok, sender: sender, recipient: recipient, conversation: conversation}
    end

    @tag :postgres_integration
    test "accept clears the flag and the chat joins the normal inbox",
         %{recipient: recipient, conversation: conversation} do
      assert {:ok, %{status: "accepted"}} =
               MessageRequests.accept(%{
                 "conversation_id" => conversation,
                 "user_id" => recipient
               })

      refute pending_at(conversation, recipient)
      assert conversation in ids(inbox(recipient))
      assert [] == ids(inbox(recipient, %{"scope" => "requests"}))
    end

    @tag :postgres_integration
    test "MUT-3 guard: decline clears the flag AND blocks the sender AND archives the chat",
         %{sender: sender, recipient: recipient, conversation: conversation} do
      assert {:ok, %{status: "declineed"}} =
               MessageRequests.decline(%{
                 "conversation_id" => conversation,
                 "user_id" => recipient
               })

      refute pending_at(conversation, recipient)

      assert {:ok, %{blocked: true}} =
               ConversationService.Blocks.either_blocked?(%{
                 "user_a" => sender,
                 "user_b" => recipient
               })

      # A declined chat must not surface in ANY of the recipient's normal lists.
      refute conversation in ids(inbox(recipient))
      assert [] == ids(inbox(recipient, %{"scope" => "requests"}))
      assert conversation in ids(inbox(recipient, %{"archived" => "true"}))
    end

    @tag :postgres_integration
    test "the SENDER cannot accept or decline their own request — same answer as a bogus id",
         %{sender: sender, conversation: conversation} do
      assert {:error, :request_not_found} =
               MessageRequests.accept(%{"conversation_id" => conversation, "user_id" => sender})

      assert {:error, :request_not_found} =
               MessageRequests.decline(%{"conversation_id" => conversation, "user_id" => sender})
    end

    @tag :postgres_integration
    test "answering twice is refused rather than silently re-running",
         %{recipient: recipient, conversation: conversation} do
      assert {:ok, _} =
               MessageRequests.accept(%{
                 "conversation_id" => conversation,
                 "user_id" => recipient
               })

      assert {:error, :request_not_found} =
               MessageRequests.accept(%{
                 "conversation_id" => conversation,
                 "user_id" => recipient
               })
    end
  end

  describe "the audience rule" do
    @tag :postgres_integration
    test "MUT-6 guard: a pending row is NOT a shared conversation, and accepting makes it one" do
      sender = user!("s")
      recipient = user!("r")
      conversation = create_direct!(sender, recipient)

      assert {:ok, %{shares: false}} =
               Conversations.shares_conversation?(%{"user_a" => sender, "user_b" => recipient})

      assert {:ok, _} =
               MessageRequests.accept(%{
                 "conversation_id" => conversation,
                 "user_id" => recipient
               })

      assert {:ok, %{shares: true}} =
               Conversations.shares_conversation?(%{"user_a" => sender, "user_b" => recipient})
    end
  end
end

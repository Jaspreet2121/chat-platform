defmodule MessageService.PollsTest do
  @moduledoc """
  Polls end-to-end on real SQL (`@tag :postgres_integration`): create (persisted with server ids, body =
  question, malformed rejected — nothing stored), vote semantics (first / change / un-vote / multi-toggle /
  single-choice rejection / unknown option / tombstone), the cold-load property (list_messages carries the
  aggregate), and THE MISSED-EVENT PROPERTY — a client that never saw poll_updated and refetches history
  sees results IDENTICAL to the vote response, because both are computed from poll_votes (the broadcast is
  never the source of truth). Departed voters' rows survive (votes are history; the membership gate lives
  in the gateway).
  """
  use MessageService.DataCase, async: false

  alias MessageService.{Messages, MessageStore, Polls}

  @conv "11111111-1111-4111-8111-111111111111"
  @sender "22222222-2222-4222-8222-222222222222"
  @alice "33333333-3333-4333-8333-333333333333"
  @bob "44444444-4444-4444-8444-444444444444"

  setup do
    prev = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      adapter:
        Application.get_env(
          :message_service,
          :message_store_adapter,
          MessageStore.QueryPlanAdapter
        )
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, MessageStore.PostgresAdapter)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persistence)
      Application.put_env(:message_service, :message_store_adapter, prev.adapter)
    end)

    :ok
  end

  defp create_poll!(overrides \\ %{}) do
    poll =
      Map.merge(
        %{
          "question" => "Lunch where?",
          "options" => [%{"text" => "Sushi"}, %{"text" => "Pizza"}]
        },
        overrides
      )

    Messages.create_message(%{
      "conversation_id" => @conv,
      "sender_user_id" => @sender,
      "message_type" => "poll",
      "metadata" => %{"poll" => poll}
    })
  end

  defp vote(mid, user, ids),
    do:
      Polls.vote(%{
        "conversation_id" => @conv,
        "message_id" => mid,
        "user_id" => user,
        "option_ids" => ids
      })

  defp history_poll(mid) do
    {:ok, %{messages: messages}} =
      Messages.list_messages(%{"conversation_id" => @conv, "viewer_user_id" => @sender})

    Enum.find(messages, &(&1.message_id == mid)).poll
  end

  defp counts(aggregate), do: Enum.map(aggregate.options, &{&1.id, &1.count})

  @tag :postgres_integration
  test "create: persisted with stable server ids, body = question, zero aggregate in the ack" do
    assert {:ok, created} = create_poll!()

    assert created.message_type == "poll"
    assert created.body == "Lunch where?"
    assert created.metadata["poll"]["options"] |> Enum.map(& &1["id"]) == ["o1", "o2"]
    assert created.poll.total_voters == 0
    assert counts(created.poll) == [{"o1", 0}, {"o2", 0}]

    # The history fetch shows the same fresh poll (cold-load correct from birth).
    assert history_poll(created.message_id).question == "Lunch where?"
  end

  @tag :postgres_integration
  test "a malformed poll is REJECTED with its code and nothing is stored" do
    assert {:error, :poll_too_few_options} = create_poll!(%{"options" => [%{"text" => "One"}]})
    assert {:error, :poll_invalid_question} = create_poll!(%{"question" => ""})

    {:ok, %{messages: messages}} =
      Messages.list_messages(%{"conversation_id" => @conv, "viewer_user_id" => @sender})

    assert messages == []
  end

  @tag :postgres_integration
  test "vote semantics: first vote, change, un-vote (single-choice replaces wholesale)" do
    {:ok, created} = create_poll!()
    mid = created.message_id

    # First vote.
    assert {:ok, %{poll: a1}} = vote(mid, @alice, ["o1"])
    assert counts(a1) == [{"o1", 1}, {"o2", 0}]
    assert hd(a1.options).voter_ids == [@alice]

    # Change — REPLACES (never two rows for a single-choice poll).
    assert {:ok, %{poll: a2}} = vote(mid, @alice, ["o2"])
    assert counts(a2) == [{"o1", 0}, {"o2", 1}]

    # Un-vote — the empty set.
    assert {:ok, %{poll: a3}} = vote(mid, @alice, [])
    assert counts(a3) == [{"o1", 0}, {"o2", 0}]
    assert a3.total_voters == 0

    # Guards: >1 id on single-choice; an id outside the definition; unknown message.
    assert {:error, :poll_single_choice} = vote(mid, @alice, ["o1", "o2"])
    assert {:error, :poll_invalid_option} = vote(mid, @alice, ["o9"])
    assert {:error, :message_not_found} = vote(Ecto.UUID.generate(), @alice, ["o1"])
  end

  @tag :postgres_integration
  test "multi-choice: the submitted set IS the vote; total_voters counts distinct users" do
    {:ok, created} = create_poll!(%{"allows_multiple" => true})
    mid = created.message_id

    assert {:ok, _} = vote(mid, @alice, ["o1", "o2"])
    assert {:ok, %{poll: both}} = vote(mid, @bob, ["o1"])
    assert counts(both) == [{"o1", 2}, {"o2", 1}]
    # 3 option-votes, 2 humans.
    assert both.total_voters == 2

    # Toggle o2 off for alice = submit her new full set.
    assert {:ok, %{poll: toggled}} = vote(mid, @alice, ["o1"])
    assert counts(toggled) == [{"o1", 2}, {"o2", 0}]
  end

  @tag :postgres_integration
  test "THE MISSED-EVENT PROPERTY: a cold history fetch equals the vote response, always" do
    {:ok, created} = create_poll!(%{"allows_multiple" => true})
    mid = created.message_id

    # Several vote writes — pretend a client saw NONE of the poll_updated broadcasts.
    {:ok, _} = vote(mid, @alice, ["o1"])
    {:ok, _} = vote(mid, @bob, ["o1", "o2"])
    {:ok, %{poll: live}} = vote(mid, @alice, ["o2"])

    # The client that missed every event and refetches history sees EXACTLY what the live client saw:
    # both shapes are computed from poll_votes at read time — the broadcast is never the source of truth.
    assert history_poll(mid) == live

    # A tombstoned poll takes its votes off the wire too (404 on vote; history hides the body per the
    # delete flow — voting is simply dead).
    {:ok, _} =
      Messages.delete_message(%{
        "conversation_id" => @conv,
        "message_id" => mid,
        "actor_user_id" => @sender
      })

    assert {:error, :message_not_found} = vote(mid, @bob, ["o1"])
  end

  @tag :postgres_integration
  test "a DEPARTED voter's rows survive (votes are history); the full list endpoint returns everything" do
    {:ok, created} = create_poll!()
    mid = created.message_id

    {:ok, _} = vote(mid, @alice, ["o1"])
    {:ok, _} = vote(mid, @bob, ["o1"])

    # "@alice leaves" — at the message layer nothing changes her rows (the gateway membership gate is
    # what stops her voting again); her vote stays counted, exactly like a departed reader's receipt.
    assert counts(history_poll(mid)) == [{"o1", 2}, {"o2", 0}]

    # The view-votes read returns the uncapped lists.
    {:ok, %{poll: full}} = Polls.list_votes(%{"conversation_id" => @conv, "message_id" => mid})
    assert hd(full.options).voter_ids == [@alice, @bob]
  end
end

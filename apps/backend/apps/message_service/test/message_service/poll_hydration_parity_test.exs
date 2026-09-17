defmodule MessageService.PollHydrationParityTest do
  @moduledoc """
  POLLS RENDERED EMPTY ON EVERY REAL TIMELINE. Options and vote counts were hydrated only on the
  Postgres adapter's list path, and production runs the Scylla adapter — so `list_messages` returned
  poll messages with no aggregate at all, while the Postgres page (which nothing in production
  serves) was correct. Production showed 5 real votes against polls nobody could see.

  The fix reuses the SAME batched builder for both adapters, and this suite is the pin: the two
  must answer IDENTICALLY for the same rows, so a change to one that forgets the other fails here.
  """
  use MessageService.DataCase, async: false

  alias MessageService.MessageStore
  alias MessageService.MessageStore.PostgresAdapter
  alias MessageService.{Messages, Polls}

  @tenant "00000000-0000-0000-0000-000000000001"

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

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'active', now(), now())",
      [id, @tenant, "+1555#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp conversation!(members) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO conversations (id, app_id, type, created_by, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, 'group', $3::text::uuid, 'active', now(), now())",
      [id, @tenant, hd(members)]
    )

    for member <- members do
      Repo.query!(
        "INSERT INTO conversation_participants (conversation_id, user_id, role, joined_at) " <>
          "VALUES ($1::text::uuid, $2::text::uuid, 'member', now())",
        [id, member]
      )
    end

    id
  end

  defp poll!(conversation, author) do
    {:ok, message} =
      Messages.create_message(%{
        "conversation_id" => conversation,
        "sender_user_id" => author,
        "message_type" => "poll",
        "metadata" => %{
          "poll" => %{
            "question" => "Pizza or curry?",
            "options" => [%{"text" => "Pizza"}, %{"text" => "Curry"}],
            "allows_multiple" => false
          }
        }
      })

    message
  end

  @tag :postgres_integration
  test "MUT-5/MUT-7 guard: the batched builder answers the FULL aggregate, and both adapters agree" do
    author = user!()
    voter = user!()
    conversation = conversation!([author, voter])
    poll = poll!(conversation, author)

    {:ok, _} =
      Polls.vote(%{
        "conversation_id" => conversation,
        "message_id" => poll.message_id,
        "user_id" => author,
        "option_ids" => ["o1"]
      })

    {:ok, _} =
      Polls.vote(%{
        "conversation_id" => conversation,
        "message_id" => poll.message_id,
        "user_id" => voter,
        "option_ids" => ["o2"]
      })

    # The POSTGRES page — what was already correct.
    {:ok, %{messages: [pg_row]}} =
      Messages.list_messages(%{"conversation_id" => conversation, "viewer_user_id" => author})

    assert pg_row.poll.question == "Pizza or curry?"
    assert pg_row.poll.total_voters == 2

    # The builder the SCYLLA path now calls, given the same message shaped as a Scylla response.
    scylla_shaped = %{
      message_id: poll.message_id,
      message_type: "poll",
      metadata: %{"poll" => poll.metadata["poll"]}
    }

    summaries = PostgresAdapter.poll_summaries([scylla_shaped])
    aggregate = Map.get(summaries, poll.message_id)

    refute is_nil(aggregate),
           "the Scylla path's builder returned nothing — this is the bug that shipped"

    # IDENTICAL, key for key and count for count.
    assert aggregate == pg_row.poll
    assert Enum.map(aggregate.options, & &1.count) == [1, 1]
    assert aggregate.total_voters == 2
  end

  @tag :postgres_integration
  test "MUT-5 guard: the SCYLLA list path — the one production serves — returns the FULL aggregate" do
    author = user!()
    voter = user!()
    conversation = conversation!([author, voter])
    poll = poll!(conversation, author)

    for {user_id, option} <- [{author, "o1"}, {voter, "o1"}] do
      {:ok, _} =
        Polls.vote(%{
          "conversation_id" => conversation,
          "message_id" => poll.message_id,
          "user_id" => user_id,
          "option_ids" => [option]
        })
    end

    # Switch to the adapter PRODUCTION runs, with the fake Scylla client the boundary suite uses.
    # The poll message is re-created through it so the row exists in that store.
    Application.put_env(:message_service, :message_store_adapter, MessageStore.ScyllaAdapter)
    Application.put_env(:message_service, :scylla_client_adapter, MessageService.TestScyllaClient)

    case MessageService.TestScyllaClient.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    MessageService.TestScyllaClient.reset()

    scylla_poll = poll!(conversation, author)

    {:ok, _} =
      Polls.vote(%{
        "conversation_id" => conversation,
        "message_id" => scylla_poll.message_id,
        "user_id" => author,
        "option_ids" => ["o2"]
      })

    {:ok, %{messages: messages}} =
      Messages.list_messages(%{"conversation_id" => conversation, "viewer_user_id" => author})

    row = Enum.find(messages, &(&1.message_id == scylla_poll.message_id))
    refute is_nil(row), "the poll is missing from the Scylla page entirely"

    refute is_nil(row.poll),
           "the Scylla page returned a poll with NO aggregate — options and counts invisible, " <>
             "which is exactly what shipped"

    assert row.poll.question == "Pizza or curry?"
    assert Enum.map(row.poll.options, & &1.text) == ["Pizza", "Curry"]
    assert Enum.map(row.poll.options, & &1.count) == [0, 1]
    assert row.poll.total_voters == 1
  end

  @tag :postgres_integration
  test "MUT-6 guard: the page costs ONE votes query however many polls are on it" do
    author = user!()
    conversation = conversation!([author])
    polls = for _ <- 1..4, do: poll!(conversation, author)

    for poll <- polls do
      {:ok, _} =
        Polls.vote(%{
          "conversation_id" => conversation,
          "message_id" => poll.message_id,
          "user_id" => author,
          "option_ids" => ["o1"]
        })
    end

    rows =
      Enum.map(polls, fn p ->
        %{
          message_id: p.message_id,
          message_type: "poll",
          metadata: %{"poll" => p.metadata["poll"]}
        }
      end)

    {queries, summaries} = count_queries(fn -> PostgresAdapter.poll_summaries(rows) end)

    assert map_size(summaries) == 4

    assert queries == 1,
           "4 polls cost #{queries} queries — the builder must batch, not read per row"

    for poll <- polls do
      assert Map.get(summaries, poll.message_id).total_voters == 1
    end
  end

  # Counts the SELECTs the function issues, via Ecto's telemetry — the only honest way to assert
  # "batched" rather than trusting the shape of the code.
  defp count_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = {__MODULE__, ref}

    :telemetry.attach(
      handler,
      [:message_service, :repo, :query],
      fn _event, _measure, meta, _config ->
        if is_binary(meta[:query]) and String.starts_with?(meta[:query], "SELECT"),
          do: send(parent, {ref, :query})
      end,
      nil
    )

    result = fun.()
    :telemetry.detach(handler)
    {drain(ref, 0), result}
  end

  defp drain(ref, count) do
    receive do
      {^ref, :query} -> drain(ref, count + 1)
    after
      0 -> count
    end
  end
end

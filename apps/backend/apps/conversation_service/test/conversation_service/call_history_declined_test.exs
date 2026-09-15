defmodule ConversationService.CallHistoryDeclinedTest do
  @moduledoc """
  A declined call IS a history row. Direct: `mark_declined/1` flips the call row to "declined" with
  ended_at and NO duration (never connected), and `list_calls_for_user/1` lists it for both parties
  (MUT-5: the row must say declined; MUT-6: a declined row never carries a duration). Group: a
  member's decline lives on their participant row, and the history now carries it as
  `participant_status` so the client can show THEIR outcome on a call that went on without them.
  """
  use ConversationService.DataCase, async: false

  alias ConversationService.CallStore

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      Application.put_env(:conversation_service, :conversation_persistence, previous)
    end)

    :ok
  end

  defp history(user_id) do
    {:ok, %{calls: calls}} = CallStore.list_calls_for_user(%{"user_id" => user_id})
    calls
  end

  @tag :postgres_integration
  test "DIRECT: decline writes the declined row, listed for caller and callee, duration nil (0 at presentation)" do
    caller = Ecto.UUID.generate()
    callee = Ecto.UUID.generate()

    {:ok, call} =
      CallStore.create_call(%{"caller_id" => caller, "callee_id" => callee, "type" => "voice"})

    # It rang for half a minute before the refusal: ringing time must never become a "duration".
    Repo.query!(
      "UPDATE calls SET created_at = created_at - interval '30 seconds' WHERE id = $1::text::uuid",
      [call.id]
    )

    assert {:ok, declined} = CallStore.mark_declined(%{"call_id" => call.id})
    assert declined.status == "declined"
    assert is_binary(declined.ended_at)
    assert declined.answered_at == nil
    # MUT-6 guard: never connected → no duration, not "time spent ringing".
    assert declined.duration_seconds == nil

    for viewer <- [caller, callee] do
      assert [row] = history(viewer)
      assert row.id == call.id
      assert row.status == "declined"
      assert row.duration_seconds == nil
      # Direct rows carry no participant status; the call row IS the viewer's outcome.
      assert row.participant_status == nil
    end

    # KEY-SET: the history row is the call response + participant_status, nothing else moved.
    assert history(callee) |> hd() |> Map.keys() |> Enum.sort() ==
             [
               :answered_at,
               :app_id,
               :callee_id,
               :caller_id,
               :conversation_id,
               :created_at,
               :duration_seconds,
               :e2ee,
               :e2ee_accepted,
               :e2ee_offer,
               :ended_at,
               :id,
               :kind,
               :participant_status,
               :room_name,
               :status,
               :type
             ]
  end

  @tag :postgres_integration
  test "GROUP: a member's decline is on THEIR history row as participant_status; the call row keeps the call's outcome" do
    owner = Ecto.UUID.generate()
    decliner = Ecto.UUID.generate()
    joiner = Ecto.UUID.generate()

    for id <- [owner, decliner, joiner] do
      Repo.query!(
        "INSERT INTO users_auth (id, email, status) VALUES ($1::text::uuid, $2, 'active')",
        [id, "hist-#{System.unique_integer([:positive])}@example.test"]
      )
    end

    {:ok, conv} =
      ConversationService.Conversations.create_conversation(%{
        "type" => "group",
        "title" => "Call Squad",
        "created_by" => owner,
        "participant_user_ids" => [decliner, joiner]
      })

    {:ok, %{call: call}} =
      CallStore.create_group_call(%{
        "initiator_id" => owner,
        "conversation_id" => conv.conversation_id,
        "type" => "voice"
      })

    assert {:ok, _} = CallStore.join_group_call(%{"call_id" => call.id, "user_id" => joiner})
    assert {:ok, _} = CallStore.decline_group_call(%{"call_id" => call.id, "user_id" => decliner})

    assert [row] = history(decliner)
    assert row.id == call.id
    assert row.participant_status == "declined"
    refute row.status == "declined"

    assert [joined] = history(joiner)
    assert joined.participant_status == "joined"
  end
end

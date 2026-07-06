defmodule ConversationService.CallStoreTest do
  use ConversationService.DataCase, async: false

  alias ConversationService.CallStore

  setup do
    previous = Application.get_env(:conversation_service, :conversation_persistence, false)
    Application.put_env(:conversation_service, :conversation_persistence, true)
    on_exit(fn -> Application.put_env(:conversation_service, :conversation_persistence, previous) end)
    :ok
  end

  @tag :postgres_integration
  test "call lifecycle persists: create (ringing) → answer → end; history lists both sides" do
    caller = Ecto.UUID.generate()
    callee = Ecto.UUID.generate()

    # create → a ringing row with a generated id + unique room_name.
    assert {:ok, call} =
             CallStore.create_call(%{
               "caller_id" => caller,
               "callee_id" => callee,
               "type" => "voice"
             })

    assert call.status == "ringing"
    assert call.caller_id == caller
    assert call.callee_id == callee
    assert call.type == "voice"
    assert is_binary(call.room_name) and call.room_name != ""
    assert is_binary(call.created_at)
    assert is_nil(call.answered_at)
    assert is_nil(call.ended_at)

    # answer → accepted + answered_at.
    assert {:ok, answered} = CallStore.mark_answered(%{"call_id" => call.id})
    assert answered.status == "accepted"
    assert is_binary(answered.answered_at)

    # end → ended + ended_at.
    assert {:ok, ended} = CallStore.mark_ended(%{"call_id" => call.id})
    assert ended.status == "ended"
    assert is_binary(ended.ended_at)

    # get_call reflects the final persisted state.
    assert {:ok, fetched} = CallStore.get_call(%{"call_id" => call.id})
    assert fetched.status == "ended"
    assert fetched.id == call.id

    # History includes the call for BOTH the caller and the callee.
    assert {:ok, %{calls: caller_calls}} = CallStore.list_calls_for_user(%{"user_id" => caller})
    assert Enum.any?(caller_calls, &(&1.id == call.id))

    assert {:ok, %{calls: callee_calls}} = CallStore.list_calls_for_user(%{"user_id" => callee})
    assert Enum.any?(callee_calls, &(&1.id == call.id))
  end

  @tag :postgres_integration
  test "decline + missed transitions; unknown id → :call_not_found" do
    caller = Ecto.UUID.generate()
    callee = Ecto.UUID.generate()

    {:ok, c1} = CallStore.create_call(%{"caller_id" => caller, "callee_id" => callee, "type" => "video"})
    assert {:ok, declined} = CallStore.mark_declined(%{"call_id" => c1.id})
    assert declined.status == "declined"
    assert is_binary(declined.ended_at)

    {:ok, c2} = CallStore.create_call(%{"caller_id" => caller, "callee_id" => callee, "type" => "voice"})
    assert {:ok, missed} = CallStore.mark_missed(%{"call_id" => c2.id})
    assert missed.status == "missed"

    assert {:error, :call_not_found} = CallStore.get_call(%{"call_id" => Ecto.UUID.generate()})
  end

  @tag :postgres_integration
  test "invalid input is rejected without persisting" do
    # missing callee/type
    assert {:error, :call_invalid} = CallStore.create_call(%{"caller_id" => Ecto.UUID.generate()})
    # bad type fails the changeset validation
    assert {:error, :call_invalid} =
             CallStore.create_call(%{
               "caller_id" => Ecto.UUID.generate(),
               "callee_id" => Ecto.UUID.generate(),
               "type" => "hologram"
             })
  end
end

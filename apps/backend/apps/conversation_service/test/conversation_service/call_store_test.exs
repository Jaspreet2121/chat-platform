defmodule ConversationService.CallStoreTest do
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

    {:ok, c1} =
      CallStore.create_call(%{"caller_id" => caller, "callee_id" => callee, "type" => "video"})

    assert {:ok, declined} = CallStore.mark_declined(%{"call_id" => c1.id})
    assert declined.status == "declined"
    assert is_binary(declined.ended_at)

    {:ok, c2} =
      CallStore.create_call(%{"caller_id" => caller, "callee_id" => callee, "type" => "voice"})

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

  # ---- 097: tenant stamping + app-gated history + cursor + cancelled/duration --------------------

  @tag :postgres_integration
  test "097: app_id stamps the row; the list gates by app — foreign hidden, NULL legacy visible" do
    caller = Ecto.UUID.generate()
    callee = Ecto.UUID.generate()
    app = Ecto.UUID.generate()
    foreign_app = Ecto.UUID.generate()

    create = fn extra ->
      {:ok, call} =
        CallStore.create_call(
          Map.merge(
            %{"caller_id" => caller, "callee_id" => callee, "type" => "voice"},
            extra
          )
        )

      call
    end

    mine = create.(%{"app_id" => app})
    legacy = create.(%{})

    # Contrived: in production a user id is app-scoped so a foreign-app row can't share this caller —
    # but the GATE must be structural, not lean on that invariant.
    foreign = create.(%{"app_id" => foreign_app})

    assert mine.app_id == app
    assert is_nil(legacy.app_id)

    # App-scoped list: own-app + legacy NULL rows only.
    assert {:ok, %{calls: gated}} =
             CallStore.list_calls_for_user(%{"user_id" => caller, "app_id" => app})

    gated_ids = Enum.map(gated, & &1.id)
    assert mine.id in gated_ids
    assert legacy.id in gated_ids
    refute foreign.id in gated_ids

    # No app in attrs (legacy caller) → unfiltered, exactly the pre-097 behaviour.
    assert {:ok, %{calls: all}} = CallStore.list_calls_for_user(%{"user_id" => caller})
    assert length(all) == 3
  end

  @tag :postgres_integration
  test "097: cancelled is its own terminal status; duration_seconds only when the call connected" do
    caller = Ecto.UUID.generate()
    callee = Ecto.UUID.generate()

    base = %{"caller_id" => caller, "callee_id" => callee, "type" => "voice"}

    # Caller hung up while ringing → cancelled (previously folded into missed), never connected → nil.
    {:ok, c1} = CallStore.create_call(base)
    assert {:ok, cancelled} = CallStore.mark_cancelled(%{"call_id" => c1.id})
    assert cancelled.status == "cancelled"
    assert is_binary(cancelled.ended_at)
    assert is_nil(cancelled.duration_seconds)

    # Answered then ended → integer duration (ended_at − answered_at, floored at 0).
    {:ok, c2} = CallStore.create_call(base)
    assert {:ok, _} = CallStore.mark_answered(%{"call_id" => c2.id})
    assert {:ok, ended} = CallStore.mark_ended(%{"call_id" => c2.id})
    assert ended.status == "ended"
    assert is_integer(ended.duration_seconds) and ended.duration_seconds >= 0
  end

  @tag :postgres_integration
  test "097: keyset cursor pages the history newest-first without overlap or loss" do
    caller = Ecto.UUID.generate()

    ids =
      for _ <- 1..3 do
        {:ok, call} =
          CallStore.create_call(%{
            "caller_id" => caller,
            "callee_id" => Ecto.UUID.generate(),
            "type" => "voice"
          })

        call.id
      end

    assert {:ok, %{calls: page1, next_cursor: cursor}} =
             CallStore.list_calls_for_user(%{"user_id" => caller, "limit" => 2})

    assert length(page1) == 2
    assert %{ts: ts, id: id} = cursor

    assert {:ok, %{calls: page2, next_cursor: last_cursor}} =
             CallStore.list_calls_for_user(%{
               "user_id" => caller,
               "limit" => 2,
               "cursor_ts" => ts,
               "cursor_id" => id
             })

    assert length(page2) == 1
    # The final short page carries no cursor, and the pages tile the set exactly.
    assert is_nil(last_cursor)
    assert Enum.sort(Enum.map(page1 ++ page2, & &1.id)) == Enum.sort(ids)
  end
end

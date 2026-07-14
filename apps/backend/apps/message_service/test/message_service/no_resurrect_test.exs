defmodule MessageService.NoResurrectTest do
  @moduledoc """
  A soft-deleted message must accept NO update. Before this guard, `fetch_own_message/4` matched the sender
  but never checked status, so a body edit set status="edited" + edited_at and brought the tombstone back to
  life — on BOTH the /v1 and socket paths (they share update_message_in_store).

  Docker-free: swaps in a tiny MessageStore adapter so we drive the real Messages gate without a DB.
  """
  use ExUnit.Case, async: false

  alias MessageService.Messages

  @conv "conv-1"
  @author "u-author"
  @other "u-other"

  defmodule StoreStub do
    @moduledoc false
    # Rows keyed by message_id. Shape copied from the Postgres adapter's message_response/1 — it exposes
    # BOTH `status` and `deleted_at`, which is what the guard reads.
    def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)

    def put(id, row), do: Agent.update(__MODULE__, &Map.put(&1, id, row))
    def get(id), do: Agent.get(__MODULE__, &Map.get(&1, id))

    def get_message(%{"message_id" => id}) do
      case get(id) do
        nil -> {:error, :message_not_found}
        row -> {:ok, row}
      end
    end

    # The real store MERGES the update onto the row — that's how the resurrect happened (status flipped to
    # "edited" while deleted_at stayed set). Model it faithfully so a regression would actually show.
    def update_message(%{"message_id" => id} = attrs) do
      row = get(id) || %{}
      merged = Enum.reduce(attrs, row, fn {k, v}, acc -> Map.put(acc, String.to_atom(k), v) end)
      put(id, merged)
      {:ok, merged}
    end

    def delete_message(%{"message_id" => id} = attrs) do
      row = get(id) || %{}
      merged = Enum.reduce(attrs, row, fn {k, v}, acc -> Map.put(acc, String.to_atom(k), v) end)
      put(id, merged)
      {:ok, merged}
    end
  end

  setup do
    start_supervised!(%{id: StoreStub, start: {StoreStub, :start_link, []}})

    prev_persist = Application.get_env(:message_service, :message_persistence, false)
    prev_adapter = Application.get_env(:message_service, :message_store_adapter)
    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :message_store_adapter, StoreStub)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev_persist)

      if prev_adapter,
        do: Application.put_env(:message_service, :message_store_adapter, prev_adapter),
        else: Application.delete_env(:message_service, :message_store_adapter)
    end)

    :ok
  end

  defp seed_active(id) do
    StoreStub.put(id, %{
      conversation_id: @conv,
      message_id: id,
      sender_user_id: @author,
      message_type: "text",
      body: "original",
      status: "active",
      metadata: %{},
      deleted_at: nil,
      edited_at: nil
    })
  end

  defp seed_deleted(id) do
    seed_active(id)

    {:ok, _} =
      Messages.delete_message(%{
        "conversation_id" => @conv,
        "message_id" => id,
        "actor_user_id" => @author
      })
  end

  defp edit(id, actor, body) do
    Messages.update_message(%{
      "conversation_id" => @conv,
      "message_id" => id,
      "actor_user_id" => actor,
      "body" => body
    })
  end

  test "REGRESSION GUARD: editing an ACTIVE own message still works" do
    seed_active("m1")

    assert {:ok, response} = edit("m1", @author, "edited text")
    assert response.body == "edited text"
    assert response.status == "edited"
    assert response.edited_at

    assert StoreStub.get("m1").deleted_at == nil
  end

  test "editing a SOFT-DELETED own message is refused — the tombstone is NOT resurrected" do
    seed_deleted("m1")
    before = StoreStub.get("m1")
    assert before.status == "deleted"
    assert before.deleted_at

    assert {:error, :message_deleted} = edit("m1", @author, "back from the dead")

    # The row is untouched: still deleted, still the original body, no edited_at.
    row = StoreStub.get("m1")
    assert row.status == "deleted"
    assert row.deleted_at == before.deleted_at
    assert row.body == "original"
    refute Map.get(row, :edited_at)
  end

  test "a live-location :metadata patch on a deleted message is ALSO refused (same gate)" do
    seed_deleted("m1")

    assert {:error, :message_deleted} =
             Messages.update_message(%{
               "conversation_id" => @conv,
               "message_id" => "m1",
               "actor_user_id" => @author,
               "metadata_patch" => %{"lat" => "1.0", "lng" => "2.0"}
             })

    assert StoreStub.get("m1").status == "deleted"
  end

  test "a NON-author gets :message_forbidden — never learns the message is deleted" do
    seed_deleted("m1")

    # Author is checked BEFORE the deleted state, so a stranger can't distinguish "deleted" from "not yours".
    assert {:error, :message_forbidden} = edit("m1", @other, "nope")

    # And on an ACTIVE message the same stranger gets the same error — indistinguishable.
    seed_active("m2")
    assert {:error, :message_forbidden} = edit("m2", @other, "nope")
  end

  test "re-DELETING an already-deleted message stays idempotent (unchanged behaviour)" do
    seed_deleted("m1")

    # The delete gate (authorize_author) has no deleted-check — a re-delete simply re-stamps the tombstone.
    # Harmless and deliberately left alone: it does not resurrect anything.
    assert {:ok, response} =
             Messages.delete_message(%{
               "conversation_id" => @conv,
               "message_id" => "m1",
               "actor_user_id" => @author
             })

    assert response.deleted == true
    assert StoreStub.get("m1").status == "deleted"
  end
end

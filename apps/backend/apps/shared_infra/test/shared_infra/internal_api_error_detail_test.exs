defmodule SharedInfra.InternalApiErrorDetailTest do
  @moduledoc """
  THE SEAM THAT FAILED ON DEVICE. A `checklist_stale` refusal carries the item's current state as a
  THIRD tuple element. `encode_result/1` had no clause for that shape, so it fell to the bare-value
  catch-all and was encoded as `{"result": {:error, :checklist_stale, %{…}}}` — a TUPLE, which
  `Jason.encode!` cannot encode. The internal call 500'd, the gateway mapped that to
  `:message_unavailable`, and the user saw 503 "service unavailable" for a routine 409.
  Reproduced 3/3 on real devices against production.

  These tests run the REAL encoder and the REAL decoder — no stub stands in for the thing that
  broke — and assert the envelope actually survives `Jason.encode!`, which is where it died.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.InternalApi

  @item %{
    id: "i1",
    done: true,
    done_by: "22222222-2222-4222-8222-222222222222",
    done_at: "2026-09-18T10:00:00.000000Z"
  }

  test "a three-element error ENCODES to a JSON-serialisable envelope" do
    envelope = InternalApi.encode_result({:error, :checklist_stale, @item})

    assert envelope == %{
             "error" => "checklist_stale",
             "detail" => @item
           }

    # The actual failure: this call raised before the fix.
    assert json = Jason.encode!(envelope)
    assert json =~ "checklist_stale"
    assert json =~ "2026-09-18T10:00:00.000000Z"
  end

  test "ROUND TRIP through the real encoder, real JSON and real decoder rebuilds the tuple" do
    original = {:error, :checklist_stale, @item}

    decoded =
      original
      |> InternalApi.encode_result()
      |> Jason.encode!()
      |> Jason.decode!()
      |> InternalApi.decode_result()

    assert decoded == original
    assert {:error, :checklist_stale, item} = decoded
    assert item.done == true
    assert item.done_by == "22222222-2222-4222-8222-222222222222"
    assert Map.keys(item) |> Enum.sort() == [:done, :done_at, :done_by, :id]
  end

  test "the two-element error is UNCHANGED — the new clause did not shadow it" do
    assert InternalApi.encode_result({:error, :message_not_found}) == %{
             "error" => "message_not_found"
           }

    assert {:error, :message_not_found} =
             {:error, :message_not_found}
             |> InternalApi.encode_result()
             |> Jason.encode!()
             |> Jason.decode!()
             |> InternalApi.decode_result()
  end

  test "an {:ok, map} and a bare value still round-trip exactly as before" do
    assert {:ok, %{message_id: "m-1", checklist: %{done_count: 1}}} =
             {:ok, %{message_id: "m-1", checklist: %{done_count: 1}}}
             |> InternalApi.encode_result()
             |> Jason.encode!()
             |> Jason.decode!()
             |> InternalApi.decode_result()

    assert true ==
             true
             |> InternalApi.encode_result()
             |> Jason.encode!()
             |> Jason.decode!()
             |> InternalApi.decode_result()
  end

  test "decode prefers the three-element shape — a detail must never be silently dropped" do
    # Ordering matters: %{"error" => name} would match an envelope carrying "detail" first.
    assert {:error, :checklist_stale, %{id: "i1"}} =
             InternalApi.decode_result(%{
               "error" => "checklist_stale",
               "detail" => %{"id" => "i1"}
             })
  end
end

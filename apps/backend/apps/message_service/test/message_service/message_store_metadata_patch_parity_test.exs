defmodule MessageService.MessageStoreMetadataPatchParityTest do
  @moduledoc """
  ADAPTER PARITY for the two update modes. The Postgres adapter always distinguished a metadata patch
  from a body edit; the Scylla adapter (fixed 2026-09-23, proven in ScyllaStoreIntegrationTest) and
  this in-memory adapter did not — every metadata patch became an "edited" message with a NULL body.
  This pins the in-memory adapter, which is what every Docker-free test of the update path runs on.
  """
  use ExUnit.Case, async: false

  alias MessageService.MessageStore.InMemoryAdapter

  setup do
    InMemoryAdapter.reset()
    :ok
  end

  defp put!(overrides) do
    attrs =
      Map.merge(
        %{
          "conversation_id" => Ecto.UUID.generate(),
          "bucket_date" => Date.to_iso8601(Date.utc_today()),
          "message_id" => Ecto.UUID.generate(),
          "sender_user_id" => Ecto.UUID.generate(),
          "message_type" => "live_location",
          "body" => "",
          "status" => "active",
          "metadata" => %{"lat" => "1", "lng" => "2", "live" => "true"},
          "created_at" => DateTime.utc_now()
        },
        overrides
      )

    {:ok, _} = InMemoryAdapter.put_message(attrs)
    attrs
  end

  test "a metadata patch moves ONLY metadata; a body edit marks edited" do
    m = put!(%{})

    assert {:ok, patched} =
             InMemoryAdapter.update_message(%{
               "conversation_id" => m["conversation_id"],
               "bucket_date" => m["bucket_date"],
               "message_id" => m["message_id"],
               "metadata" => %{
                 "lat" => "1",
                 "lng" => "2",
                 "live" => "false",
                 "ended_at" => "2026-09-23T10:00:00Z"
               }
             })

    assert patched.metadata["live"] == "false"
    assert patched.metadata["ended_at"] == "2026-09-23T10:00:00Z"
    assert patched.status == "active"
    assert patched.body == ""

    assert {:ok, edited} =
             InMemoryAdapter.update_message(%{
               "conversation_id" => m["conversation_id"],
               "bucket_date" => m["bucket_date"],
               "message_id" => m["message_id"],
               "body" => "typo fixed",
               "edited_at" => DateTime.utc_now()
             })

    assert edited.status == "edited"
    assert edited.body == "typo fixed"
    # The earlier patch survived the edit — the edit does not touch metadata either.
    assert edited.metadata["live"] == "false"
  end
end

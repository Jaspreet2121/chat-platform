defmodule ConversationService.Migration125Test do
  @moduledoc """
  Schema 125 is dual-written byte-identical and re-applies cleanly on a database that already carries
  it (the gate rebuilds from init/*.sql, so it does). Afterwards the table, the two participant
  columns and the partial index exist with the shapes the code relies on — and the inbox row carries
  streak_days and best_friend for a direct conversation.
  """
  use ExUnit.Case, async: false

  alias ConversationService.Repo

  @schema Path.expand("../../../shared_infra/priv/schema/125_dm_streaks_best_friend.sql", __DIR__)
  @init Path.expand(
          "../../../../../../infra/docker/postgres/init/125_dm_streaks_best_friend.sql",
          __DIR__
        )

  setup do
    case Repo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  @tag :postgres_integration
  test "dual-written byte-identical, re-applies cleanly, shapes present" do
    assert File.read!(@schema) == File.read!(@init)

    # BEGIN/COMMIT are the file's own transaction; inside the sandbox the test IS the transaction.
    @schema
    |> File.read!()
    |> SharedInfra.Release.statements()
    |> Enum.reject(&(String.upcase(&1) in ["BEGIN", "COMMIT"]))
    |> Enum.each(&Repo.query!(&1, []))

    assert %{rows: rows} =
             Repo.query!(
               "SELECT column_name, data_type FROM information_schema.columns " <>
                 "WHERE table_name = 'dm_streaks' ORDER BY column_name"
             )

    assert Enum.map(rows, &hd/1) == [
             "conversation_id",
             "last_both_sides_date",
             "streak_days",
             "updated_at"
           ]

    assert {"last_both_sides_date", "date"} =
             Enum.find(rows, &(hd(&1) == "last_both_sides_date")) |> List.to_tuple()

    for column <- ["last_message_on", "best_friend_at"] do
      assert %{rows: [[_]]} =
               Repo.query!(
                 "SELECT data_type FROM information_schema.columns " <>
                   "WHERE table_name = 'conversation_participants' AND column_name = $1",
                 [column]
               )
    end

    assert %{rows: [[definition]]} =
             Repo.query!(
               "SELECT indexdef FROM pg_indexes " <>
                 "WHERE indexname = 'conversation_participants_best_friend_idx'"
             )

    assert definition =~ "WHERE"
    assert definition =~ "best_friend_at IS NOT NULL"
  end
end

defmodule MessageService.Migration127Test do
  @moduledoc """
  Schema 127 is dual-written byte-identical and re-applies cleanly, and the partial index the sweep
  depends on exists with the predicate that keeps it proportional to the work outstanding.
  """
  use MessageService.DataCase, async: false

  @schema Path.expand("../../../shared_infra/priv/schema/127_view_once_expiry.sql", __DIR__)
  @init Path.expand(
          "../../../../../../infra/docker/postgres/init/127_view_once_expiry.sql",
          __DIR__
        )

  @tag :postgres_integration
  test "dual-written byte-identical, re-applies cleanly, shapes present" do
    assert File.read!(@schema) == File.read!(@init)

    @schema
    |> File.read!()
    |> SharedInfra.Release.statements()
    |> Enum.reject(&(String.upcase(&1) in ["BEGIN", "COMMIT"]))
    |> Enum.each(&Repo.query!(&1, []))

    assert %{rows: rows} =
             Repo.query!(
               "SELECT column_name, is_nullable FROM information_schema.columns " <>
                 "WHERE table_name = 'view_once_expiry' ORDER BY column_name"
             )

    assert Enum.map(rows, &hd/1) == [
             "app_id",
             "conversation_id",
             "created_at",
             "expires_at",
             "media_id",
             "message_id",
             "purged_at",
             "sender_user_id"
           ]

    # purged_at is the only nullable one that matters: NULL means "a purge is still owed".
    assert {"purged_at", "YES"} =
             rows |> Enum.find(&(hd(&1) == "purged_at")) |> List.to_tuple()

    # sender_user_id is NOT NULL — without it the owner-scoped purge can never run.
    assert {"sender_user_id", "NO"} =
             rows |> Enum.find(&(hd(&1) == "sender_user_id")) |> List.to_tuple()

    assert %{rows: [[definition]]} =
             Repo.query!(
               "SELECT indexdef FROM pg_indexes WHERE indexname = 'view_once_expiry_due_idx'"
             )

    assert definition =~ "expires_at"
    assert definition =~ "WHERE"
    assert definition =~ "purged_at IS NULL"
  end
end

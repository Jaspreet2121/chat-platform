defmodule MediaService.Migration124VariantsTest do
  @moduledoc """
  Schema 124 is idempotent: applying its statements again on a database that already carries them
  (the gate rebuilds from init/*.sql, so it has) changes nothing and raises nothing; afterwards the
  column and the partial queue index exist with the shapes the code relies on.
  """
  use ExUnit.Case, async: false

  @moduletag :postgres_integration

  alias MediaService.Repo, as: MediaRepo

  @schema Path.expand("../../../shared_infra/priv/schema/124_media_assets_variants.sql", __DIR__)
  @init Path.expand(
          "../../../../../../infra/docker/postgres/init/124_media_assets_variants.sql",
          __DIR__
        )

  setup do
    case MediaRepo.start_link() do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(MediaRepo)
    :ok
  end

  test "dual-written byte-identical, re-applies cleanly, column + queue index present" do
    assert File.read!(@schema) == File.read!(@init)

    # BEGIN/COMMIT are the file's own transaction; inside the sandbox the test IS the transaction.
    @schema
    |> File.read!()
    |> SharedInfra.Release.statements()
    |> Enum.reject(&(String.upcase(&1) in ["BEGIN", "COMMIT"]))
    |> Enum.each(&MediaRepo.query!(&1, []))

    assert %{rows: [["jsonb", "YES"]]} =
             MediaRepo.query!(
               "SELECT data_type, is_nullable FROM information_schema.columns " <>
                 "WHERE table_name = 'media_assets' AND column_name = 'variants'"
             )

    assert %{rows: [[definition]]} =
             MediaRepo.query!(
               "SELECT indexdef FROM pg_indexes WHERE indexname = 'idx_media_assets_variants_pending'"
             )

    assert definition =~ "WHERE"
    assert definition =~ "variants IS NULL"
    assert definition =~ "sealed_media"
  end
end

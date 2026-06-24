defmodule SharedInfra.ReleaseSchemaDriftTest do
  @moduledoc """
  Guards the ONE duplication in the repo: `shared_infra/priv/schema/*.sql` is a release-bundled copy
  of the canonical `infra/docker/postgres/init/*.sql` (which the compose initdb mount + CI load).
  This test fails if they drift, so a schema change to one without the other can't merge silently.
  """
  use ExUnit.Case, async: true

  # __DIR__ = <repo>/apps/backend/apps/shared_infra/test/shared_infra → up 6 to <repo>.
  @canonical Path.expand("../../../../../../infra/docker/postgres/init", __DIR__)

  test "priv/schema is byte-identical to infra/docker/postgres/init (release copy in sync)" do
    priv = Application.app_dir(:shared_infra, "priv/schema")

    canonical_files = @canonical |> sql_basenames()
    priv_files = priv |> sql_basenames()

    assert canonical_files != [], "no canonical SQL found at #{@canonical}"

    assert canonical_files == priv_files,
           "schema file SET differs — infra=#{inspect(canonical_files)} priv=#{inspect(priv_files)}"

    for name <- canonical_files do
      assert File.read!(Path.join(@canonical, name)) == File.read!(Path.join(priv, name)),
             "#{name} differs between infra/docker/postgres/init and shared_infra/priv/schema — " <>
               "keep the release copy in sync (cp the canonical file into priv/schema)"
    end
  end

  defp sql_basenames(dir) do
    dir |> Path.join("*.sql") |> Path.wildcard() |> Enum.map(&Path.basename/1) |> Enum.sort()
  end
end

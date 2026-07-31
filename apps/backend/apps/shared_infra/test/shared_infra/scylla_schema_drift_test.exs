defmodule SharedInfra.ScyllaSchemaDriftTest do
  @moduledoc """
  The Scylla twin of ReleaseSchemaDriftTest: `shared_infra/priv/scylla/*.cql` is a release-bundled
  copy of the canonical `infra/docker/scylladb/init/*.cql` (which the one-shot cqlsh load and
  scripts/test-scylla.sh read). Fails if they drift, so a schema change to one without the other —
  including the metadata-JSON convention documented in the file header — can't merge silently.
  """
  use ExUnit.Case, async: true

  # __DIR__ = <repo>/apps/backend/apps/shared_infra/test/shared_infra → up 6 to <repo>.
  @canonical Path.expand("../../../../../../infra/docker/scylladb/init", __DIR__)

  test "priv/scylla is byte-identical to infra/docker/scylladb/init (release copy in sync)" do
    priv = Application.app_dir(:shared_infra, "priv/scylla")

    canonical_files = @canonical |> cql_basenames()
    priv_files = priv |> cql_basenames()

    assert canonical_files != [], "no canonical CQL found at #{@canonical}"

    assert canonical_files == priv_files,
           "CQL file SET differs — infra=#{inspect(canonical_files)} priv=#{inspect(priv_files)}"

    for name <- canonical_files do
      assert File.read!(Path.join(@canonical, name)) == File.read!(Path.join(priv, name)),
             "#{name} differs between infra/docker/scylladb/init and shared_infra/priv/scylla — " <>
               "keep the release copy in sync (cp the canonical file into priv/scylla)"
    end
  end

  defp cql_basenames(dir) do
    dir |> Path.join("*.cql") |> Path.wildcard() |> Enum.map(&Path.basename/1) |> Enum.sort()
  end
end

defmodule SharedInfra.Redis.Client do
  @moduledoc """
  Behaviour for Redis client adapters.

  The current project uses this as an interface only. Production connection
  pooling and Redis Presence integration are intentionally deferred.
  """

  @callback command(command :: [term()], opts :: keyword()) :: {:ok, term()} | {:error, term()}
  @callback pipeline(commands :: [[term()]], opts :: keyword()) :: {:ok, term()} | {:error, term()}
end

defmodule SharedInfra do
  @moduledoc """
  Shared infrastructure client boundaries for backend services.

  These modules define dependency-free behaviours, config helpers, and dummy
  adapters. Real Redis, Kafka, and ScyllaDB client processes will be added in a
  later infrastructure phase.
  """
end

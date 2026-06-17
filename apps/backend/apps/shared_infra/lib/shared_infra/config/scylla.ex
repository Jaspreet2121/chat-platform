defmodule SharedInfra.Config.Scylla do
  @moduledoc """
  Safe ScyllaDB config helpers backed by existing application config placeholders.
  """

  @default_nodes [{"localhost", 9042}]
  @default_keyspace "chat_messages"
  @default_timeout 5_000

  def from_app(app \\ :message_service, key \\ :scylla) do
    app
    |> Application.get_env(key, [])
    |> normalize()
  end

  def normalize(config) when is_list(config) do
    nodes = Keyword.get(config, :nodes) || Keyword.get(config, :contact_points) || @default_nodes

    [
      nodes: nodes,
      contact_points: nodes,
      keyspace: Keyword.get(config, :keyspace, @default_keyspace),
      timeout: Keyword.get(config, :timeout, @default_timeout)
    ]
  end

  def normalize(_config), do: normalize([])
end

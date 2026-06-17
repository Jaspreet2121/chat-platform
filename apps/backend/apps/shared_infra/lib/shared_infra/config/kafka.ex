defmodule SharedInfra.Config.Kafka do
  @moduledoc """
  Safe Kafka config helpers backed by existing application config placeholders.
  """

  @default_brokers "localhost:9094"

  def from_app(app, key \\ :kafka) do
    app
    |> Application.get_env(key, [])
    |> normalize(default_client_id(app))
  end

  def normalize(config, default_client_id \\ "backend-service")

  def normalize(config, default_client_id) when is_list(config) do
    [
      brokers: Keyword.get(config, :brokers, @default_brokers),
      client_id: Keyword.get(config, :client_id, default_client_id)
    ]
  end

  def normalize(_config, default_client_id), do: normalize([], default_client_id)

  defp default_client_id(app) do
    app
    |> Atom.to_string()
    |> String.replace("_", "-")
  end
end

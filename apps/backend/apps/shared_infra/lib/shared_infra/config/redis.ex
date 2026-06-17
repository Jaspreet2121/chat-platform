defmodule SharedInfra.Config.Redis do
  @moduledoc """
  Safe Redis config helpers backed by existing application config placeholders.
  """

  @default_url "redis://localhost:6379/0"

  def from_app(app \\ :realtime_gateway, key \\ :redis) do
    app
    |> Application.get_env(key, [])
    |> normalize()
  end

  def normalize(config) when is_list(config) do
    [
      url: Keyword.get(config, :url, @default_url),
      timeout: Keyword.get(config, :timeout, 1_000)
    ]
  end

  def normalize(_config), do: normalize([])
end

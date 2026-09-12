defmodule ApiGatewayWeb.HealthController do
  @moduledoc """
  Public liveness. Carries `git_sha` so `curl https://api.growblic.com/health` answers "is the new
  build running?" without an rpc into the container (see SharedInfra.BuildInfo).
  """
  use ApiGatewayWeb, :controller

  def show(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "api_gateway",
      git_sha: SharedInfra.BuildInfo.git_sha()
    })
  end
end

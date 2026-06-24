defmodule SharedInfra.HttpClientCorrelationIntegrationTest.EchoRouter do
  @moduledoc false
  # Reflects the inbound x-correlation-id back through the standard result envelope, so the test
  # can assert exactly what SharedInfra.HttpClient put on the wire.
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  post "/echo" do
    seen = conn |> Plug.Conn.get_req_header("x-correlation-id") |> List.first()
    body = SharedInfra.InternalApi.encode_result({:ok, %{"seen_correlation_id" => seen}})

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end

  match _ do
    Plug.Conn.send_resp(conn, 404, "{}")
  end
end

defmodule SharedInfra.HttpClientCorrelationIntegrationTest do
  @moduledoc """
  Proves LAYER B over a REAL localhost listener: `SharedInfra.HttpClient` sends `x-correlation-id`
  on an internal call when the caller's Logger metadata has one, and OMITS it when absent. Tagged
  `:http_integration` (real Cowboy listener) — excluded from the plain Docker-free suite.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Correlation
  alias SharedInfra.HttpClient
  alias SharedInfra.HttpClientCorrelationIntegrationTest.EchoRouter

  @port 4193

  setup do
    start_supervised!({Plug.Cowboy, scheme: :http, plug: EchoRouter, options: [port: @port]})
    Logger.metadata(correlation_id: nil)
    on_exit(fn -> Logger.metadata(correlation_id: nil) end)
    :ok
  end

  defp echo do
    HttpClient.post_result("http://localhost:#{@port}", "/echo", %{}, unavailable: :echo_unavailable)
  end

  @tag :http_integration
  test "sends x-correlation-id from the caller's Logger metadata" do
    Correlation.put("test-corr-123")
    assert {:ok, %{seen_correlation_id: "test-corr-123"}} = echo()
  end

  @tag :http_integration
  test "omits x-correlation-id when the caller has no correlation set" do
    assert Correlation.get() == nil
    assert {:ok, %{seen_correlation_id: nil}} = echo()
  end
end

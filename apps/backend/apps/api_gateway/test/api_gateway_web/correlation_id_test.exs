defmodule ApiGatewayWeb.CorrelationIdTest do
  # async: false — exercises per-process Logger metadata via the plug.
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias ApiGatewayWeb.Plugs.CorrelationId
  alias ApiGatewayWeb.ErrorResponse
  alias SharedInfra.Correlation

  setup do
    Logger.metadata(correlation_id: nil)
    on_exit(fn -> Logger.metadata(correlation_id: nil) end)
    :ok
  end

  describe "CorrelationId plug (gateway origin)" do
    test "mints an id when none is supplied; stashes in assign + resp header + Logger metadata" do
      conn = CorrelationId.call(conn(:get, "/"), CorrelationId.init([]))

      id = conn.assigns[:correlation_id]
      assert is_binary(id) and id != ""
      assert get_resp_header(conn, "x-correlation-id") == [id]
      assert Correlation.get() == id
    end

    test "honors a sane inbound x-correlation-id (echoed back, used as the id)" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-correlation-id", "inbound-trace-7")
        |> CorrelationId.call(CorrelationId.init([]))

      assert conn.assigns[:correlation_id] == "inbound-trace-7"
      assert get_resp_header(conn, "x-correlation-id") == ["inbound-trace-7"]
      assert Correlation.get() == "inbound-trace-7"
    end

    test "ignores a blank inbound header and mints a fresh id instead" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-correlation-id", "")
        |> CorrelationId.call(CorrelationId.init([]))

      id = conn.assigns[:correlation_id]

      # A fresh, valid id — NOT the blank inbound value — fully stashed (assign + header + metadata).
      assert is_binary(id) and id != ""
      assert get_resp_header(conn, "x-correlation-id") == [id]
      assert Correlation.get() == id
    end

    test "ignores an oversized inbound header (> max len) and mints a fresh id" do
      oversized = String.duplicate("x", 201)
      refute Correlation.valid?(oversized)

      conn =
        conn(:get, "/")
        |> put_req_header("x-correlation-id", oversized)
        |> CorrelationId.call(CorrelationId.init([]))

      id = conn.assigns[:correlation_id]
      assert is_binary(id) and id != oversized
      assert byte_size(id) <= 200
      assert get_resp_header(conn, "x-correlation-id") == [id]
      assert Correlation.get() == id
    end
  end

  describe "ErrorResponse carries the real correlation id (no placeholder)" do
    test "uses the conn's assigned correlation id in the error envelope" do
      conn =
        conn(:post, "/")
        |> assign(:correlation_id, "fixed-corr-42")
        |> ErrorResponse.invalid_request("some.code")

      assert %{"error" => %{"code" => "some.code", "correlation_id" => "fixed-corr-42"}} =
               Jason.decode!(conn.resp_body)
    end

    test "service_unavailable also carries the assigned id" do
      conn =
        conn(:post, "/")
        |> assign(:correlation_id, "fixed-corr-503")
        |> ErrorResponse.service_unavailable("auth.unavailable")

      assert %{"error" => %{"correlation_id" => "fixed-corr-503"}} =
               Jason.decode!(conn.resp_body)
    end

    test "falls back to a real generated id (never the old placeholder) when unassigned" do
      conn = ErrorResponse.invalid_request(conn(:post, "/"), "some.code")

      assert %{"error" => %{"correlation_id" => corr}} = Jason.decode!(conn.resp_body)
      assert is_binary(corr) and corr != "" and corr != "corr_placeholder"
    end
  end
end

defmodule ApiGatewayWeb.UpiQrTest do
  @moduledoc """
  The gateway's async UPI QR orchestration: it calls the user-service generator, RETRIES with backoff
  on failure (capped), and on success broadcasts `profile_changed` to the owner's user topic so their
  clients refetch and the QR appears. A permanent failure broadcasts nothing (the profile is left
  consistent; the next UPI PATCH regenerates). Nothing here touches the PATCH request path.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.UpiQr

  @me "11111111-1111-1111-1111-111111111111"
  @app "44444444-4444-4444-8444-444444444444"

  defmodule UserStub do
    @moduledoc false
    # Announces each call and pops the next programmed result from a test-controlled queue.
    def regenerate_upi_qr(attrs) do
      send(:upi_qr_test, {:regen, attrs})
      [head | tail] = Application.get_env(:api_gateway, :upi_qr_test_results, [])
      Application.put_env(:api_gateway, :upi_qr_test_results, tail)
      head
    end
  end

  setup do
    Process.register(self(), :upi_qr_test)
    prev_adapter = Application.get_env(:shared_infra, :user_client_adapter)

    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    # No real sleeping between retries.
    Application.put_env(:api_gateway, :upi_qr_base_backoff_ms, 0)
    Application.put_env(:api_gateway, :upi_qr_max_attempts, 5)

    on_exit(fn ->
      if prev_adapter,
        do: Application.put_env(:shared_infra, :user_client_adapter, prev_adapter),
        else: Application.delete_env(:shared_infra, :user_client_adapter)

      Application.delete_env(:api_gateway, :upi_qr_test_results)
      Application.delete_env(:api_gateway, :upi_qr_base_backoff_ms)
      Application.delete_env(:api_gateway, :upi_qr_max_attempts)
    end)

    :ok
  end

  defp program(results), do: Application.put_env(:api_gateway, :upi_qr_test_results, results)

  test "success on the first attempt: generates once, then broadcasts profile_changed to self" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    program([{:ok, %{upi_qr_media_id: "media-1"}}])

    assert UpiQr.run(@me, @app, 1) == :ok

    assert_receive {:regen, %{"user_id" => @me, "app_id" => @app}}

    assert_receive %Phoenix.Socket.Broadcast{
      event: "profile_changed",
      payload: %{"type" => "profile_changed"}
    }
  end

  test "retries with backoff on failure, then broadcasts once it finally succeeds" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)

    program([
      {:error, :upi_qr_failed},
      {:error, :user_unavailable},
      {:ok, %{upi_qr_media_id: "media-2"}}
    ])

    assert UpiQr.run(@me, @app, 1) == :ok

    # Three attempts total (two failures + the success).
    assert_receive {:regen, _}
    assert_receive {:regen, _}
    assert_receive {:regen, _}
    refute_receive {:regen, _}, 20

    assert_receive %Phoenix.Socket.Broadcast{event: "profile_changed"}
  end

  test "gives up after the attempt cap and broadcasts nothing" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    program(List.duplicate({:error, :upi_qr_failed}, 5))

    assert UpiQr.run(@me, @app, 1) == :error

    for _ <- 1..5, do: assert_receive({:regen, _})
    refute_receive {:regen, _}, 20
    refute_receive %Phoenix.Socket.Broadcast{event: "profile_changed"}, 50
  end

  test "nothing to generate (cleared identity): no retry, no broadcast" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    program([{:ok, %{upi_qr_media_id: nil}}])

    assert UpiQr.run(@me, @app, 1) == :ok

    assert_receive {:regen, _}
    refute_receive {:regen, _}, 20
    refute_receive %Phoenix.Socket.Broadcast{event: "profile_changed"}, 50
  end
end

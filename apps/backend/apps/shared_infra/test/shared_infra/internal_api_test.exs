defmodule SharedInfra.InternalApiTest do
  @moduledoc """
  The internal result-envelope contract + round-trip fidelity (plain, Docker-free). Atom literals
  in this test (`:user_id`, `:otp_invalid`, …) ensure those atoms exist so `decode_result`'s
  `String.to_existing_atom/1` rehydration succeeds — the same guarantee the loaded service code gives.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias SharedInfra.InternalApi

  describe "encode_result/1" do
    test "wraps {:ok, map}, {:error, atom}, and bare values" do
      assert InternalApi.encode_result({:ok, %{user_id: "u"}}) == %{"ok" => %{user_id: "u"}}
      assert InternalApi.encode_result({:error, :otp_invalid}) == %{"error" => "otp_invalid"}
      assert InternalApi.encode_result(false) == %{"result" => false}
      assert InternalApi.encode_result(true) == %{"result" => true}
    end
  end

  describe "round-trip through JSON reproduces the in-process shape EXACTLY" do
    test "{:ok, atom-keyed session map} (the current_session shape)" do
      input =
        {:ok,
         %{
           user_id: "user_placeholder",
           session_id: "sess_placeholder",
           device_id: "device_placeholder",
           platform: "ios",
           issued_at: "2026-06-16T18:00:00Z",
           expires_at: "2026-06-16T18:15:00Z"
         }}

      assert roundtrip(input) == input
    end

    test "{:error, atom} preserves the atom (gateway pattern-matches on it)" do
      assert roundtrip({:error, :otp_invalid}) == {:error, :otp_invalid}
      assert roundtrip({:error, :session_invalid}) == {:error, :session_invalid}
      assert roundtrip({:error, :refresh_invalid}) == {:error, :refresh_invalid}
    end

    test "bare boolean (persistence_enabled?)" do
      assert roundtrip(false) == false
      assert roundtrip(true) == true
    end
  end

  describe "TokenPlug (internal service-to-service auth — fails closed)" do
    setup do
      previous = Application.get_env(:shared_infra, :internal_api_token)
      Application.put_env(:shared_infra, :internal_api_token, "test-internal-token")

      on_exit(fn ->
        if previous,
          do: Application.put_env(:shared_infra, :internal_api_token, previous),
          else: Application.delete_env(:shared_infra, :internal_api_token)
      end)

      :ok
    end

    test "passes through with the correct token" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-internal-token", "test-internal-token")
        |> SharedInfra.InternalApi.TokenPlug.call([])

      refute conn.halted
    end

    test "rejects (401, halt) a missing token" do
      conn = conn(:get, "/") |> SharedInfra.InternalApi.TokenPlug.call([])
      assert conn.halted
      assert conn.status == 401
    end

    test "rejects (401, halt) a wrong token" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-internal-token", "nope")
        |> SharedInfra.InternalApi.TokenPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end

    test "fails closed when no token is configured" do
      Application.delete_env(:shared_infra, :internal_api_token)

      conn =
        conn(:get, "/")
        |> put_req_header("x-internal-token", "anything")
        |> SharedInfra.InternalApi.TokenPlug.call([])

      assert conn.halted
      assert conn.status == 401
    end
  end

  defp roundtrip(result) do
    result
    |> InternalApi.encode_result()
    |> Jason.encode!()
    |> Jason.decode!()
    |> InternalApi.decode_result()
  end
end

defmodule MediaService.HTTP.RouterTest do
  @moduledoc """
  Drives the media internal HTTP API via Plug.Test (synthetic conn — NO listener/port), plain/
  Docker-free. media_service has no Repo. `create_upload` generates a UUID (non-deterministic), so
  the OK path asserts only the envelope shape; the deterministic ERROR paths (`%{}` → `:media_invalid`)
  assert `decode_result` reconstructs the exact in-process `{:error, atom}` — exercising the error-atom
  round-trip through a real router. Plus the internal-auth plug rejection.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts MediaService.HTTP.Router.init([])
  @token "test-internal-token"

  setup do
    previous = Application.get_env(:shared_infra, :internal_api_token)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:shared_infra, :internal_api_token, previous),
        else: Application.delete_env(:shared_infra, :internal_api_token)
    end)

    :ok
  end

  defp call(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-internal-token", @token)
    |> MediaService.HTTP.Router.call(@opts)
  end

  test "POST /internal/media/create_upload (invalid) → error-atom envelope; decode == in-process" do
    conn = call("/internal/media/create_upload", %{})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert %{"error" => "media_invalid"} = body
    assert SharedInfra.InternalApi.decode_result(body) == MediaService.Media.create_upload(%{})
  end

  test "POST /internal/media/download_url (invalid) → error-atom; decode == in-process" do
    conn = call("/internal/media/download_url", %{})
    assert conn.status == 200
    body = Jason.decode!(conn.resp_body)
    assert SharedInfra.InternalApi.decode_result(body) == MediaService.Media.get_download_url(%{})
  end

  test "POST /internal/media/create_upload (valid) → {\"ok\": ...} envelope" do
    attrs = %{
      "owner_user_id" => "user_1",
      "filename" => "pic.png",
      "content_type" => "image/png",
      "size_bytes" => 1024
    }

    conn = call("/internal/media/create_upload", attrs)
    assert conn.status == 200
    assert %{"ok" => upload} = Jason.decode!(conn.resp_body)
    assert is_map(upload)
  end

  test "rejects (401) a request missing the internal token" do
    conn =
      conn(:post, "/internal/media/download_url", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> MediaService.HTTP.Router.call(@opts)

    assert conn.status == 401
    assert conn.halted
  end
end

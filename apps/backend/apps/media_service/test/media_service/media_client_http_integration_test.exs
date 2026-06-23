defmodule MediaService.MediaClientHttpIntegrationTest do
  @moduledoc """
  Proves the Media HTTP client adapter (`SharedInfra.MediaClientHttp`) round-trips over a REAL localhost
  listener and reconstructs the EXACT in-process shape + maps transport failure to
  `{:error, :media_unavailable}`. Tagged `:http_integration` (real Cowboy listener) — EXCLUDED by default.
  `create_upload` generates a UUID (non-deterministic), so the round-trip uses the deterministic ERROR
  path (`%{}` → `:media_invalid`); the OK path asserts only the envelope shape.
  """
  use ExUnit.Case, async: false

  @port 4195
  @token "test-internal-token"

  setup do
    prev_token = Application.get_env(:shared_infra, :internal_api_token)
    prev_url = Application.get_env(:shared_infra, :media_service_url)
    Application.put_env(:shared_infra, :internal_api_token, @token)

    start_supervised!(
      {Plug.Cowboy, scheme: :http, plug: MediaService.HTTP.Router, options: [port: @port]}
    )

    on_exit(fn ->
      if prev_token,
        do: Application.put_env(:shared_infra, :internal_api_token, prev_token),
        else: Application.delete_env(:shared_infra, :internal_api_token)

      if prev_url,
        do: Application.put_env(:shared_infra, :media_service_url, prev_url),
        else: Application.delete_env(:shared_infra, :media_service_url)
    end)

    :ok
  end

  @tag :http_integration
  test "create_upload (invalid) over HTTP == in-process error; valid → ok envelope" do
    Application.put_env(:shared_infra, :media_service_url, "http://localhost:#{@port}")

    # Deterministic error path: shape-identical to in-process {:error, :media_invalid}.
    assert SharedInfra.MediaClientHttp.create_upload(%{}) == MediaService.Media.create_upload(%{})

    # Valid path: UUID is non-deterministic, so assert the {:ok, _} envelope only.
    attrs = %{"owner_user_id" => "u1", "filename" => "p.png", "content_type" => "image/png", "size_bytes" => 10}
    assert {:ok, upload} = SharedInfra.MediaClientHttp.create_upload(attrs)
    assert is_map(upload)
  end

  @tag :http_integration
  test "get_download_url (invalid) over HTTP == in-process error" do
    Application.put_env(:shared_infra, :media_service_url, "http://localhost:#{@port}")

    assert SharedInfra.MediaClientHttp.get_download_url(%{}) == MediaService.Media.get_download_url(%{})
  end

  @tag :http_integration
  test "transport failure (no listener) → {:error, :media_unavailable}" do
    Application.put_env(:shared_infra, :media_service_url, "http://localhost:4190")

    assert SharedInfra.MediaClientHttp.get_download_url(%{"media_id" => "m"}) ==
             {:error, :media_unavailable}
  end
end

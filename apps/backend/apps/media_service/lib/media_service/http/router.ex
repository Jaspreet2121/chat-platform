defmodule MediaService.HTTP.Router do
  @moduledoc """
  Internal HTTP API for media-service (Plug, not Phoenix) — last of the internal-API set. Routes
  map 1:1 to `SharedInfra.MediaClient`'s contract; each calls the in-process `MediaService.Media`
  function and serializes via `SharedInfra.InternalApi.encode_result/1` (preserving the
  `:media_invalid` error atom + atom-keyed upload/download maps). Same template as
  `AuthService.HTTP.Router`. Transport auth via `SharedInfra.InternalApi.TokenPlug`.

  Started ONLY under `MEDIA_HTTP_API_ENABLED` (see `MediaService.Application`), default off → no
  listener at boot. See docs/09-devops/INTERNAL_API.md.
  """
  use Plug.Router

  plug(SharedInfra.InternalApi.TokenPlug)
  plug(SharedInfra.InternalApi.CorrelationPlug)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason)
  plug(:dispatch)

  post "/internal/media/create_upload" do
    send_result(conn, MediaService.Media.create_upload(body(conn)))
  end

  post "/internal/media/complete_upload" do
    send_result(conn, MediaService.Media.complete_upload(body(conn)))
  end

  post "/internal/media/download_url" do
    send_result(conn, MediaService.Media.get_download_url(body(conn)))
  end

  post "/internal/media/multipart/create" do
    send_result(conn, MediaService.Media.create_multipart_upload(body(conn)))
  end

  post "/internal/media/multipart/parts" do
    send_result(conn, MediaService.Media.presign_upload_parts(body(conn)))
  end

  post "/internal/media/multipart/complete" do
    send_result(conn, MediaService.Media.complete_multipart_upload(body(conn)))
  end

  post "/internal/media/multipart/abort" do
    send_result(conn, MediaService.Media.abort_multipart_upload(body(conn)))
  end

  post "/internal/media/anchor_asset" do
    send_result(conn, MediaService.Media.anchor_asset(body(conn)))
  end

  post "/internal/media/purge_asset" do
    send_result(conn, MediaService.Media.purge_asset(body(conn)))
  end

  post "/internal/media/get_asset" do
    send_result(conn, MediaService.Media.get_asset(body(conn)))
  end

  # Service health: own liveness + the dependency this service owns (MinIO object storage).
  get "/internal/health" do
    endpoint =
      Application.get_env(:media_service, :minio, [])
      |> Keyword.get(:endpoint, "http://minio:9000")

    deps = %{minio: SharedInfra.Health.http_ok(endpoint <> "/minio/health/ready")}

    send_result(conn, {:ok, %{service: "media", status: "ok", deps: deps}})
  end

  match _ do
    send_resp(conn, 404, Jason.encode!(%{"error" => "not_found"}))
  end

  defp body(%{body_params: params}) when is_map(params) and not is_struct(params), do: params
  defp body(_conn), do: %{}

  defp send_result(conn, result) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(SharedInfra.InternalApi.encode_result(result)))
  end
end

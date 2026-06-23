defmodule SharedInfra.MediaClientHttp do
  @moduledoc """
  HTTP adapter for `SharedInfra.MediaClient` — calls media-service's internal HTTP API
  (`MediaService.HTTP.Router`) over the network. Selected by `MEDIA_CLIENT_ADAPTER=http`; default stays
  `MediaService.MediaClientInProcess` (zero behavior change until flipped). Last of the client-adapter set.

  Same template as the other `*ClientHttp`: lives in shared_infra (not media_service); atom-keyed
  upload/download maps round-trip via `SharedInfra.InternalApi.decode_result/1` through
  `SharedInfra.HttpClient` (no metadata caveat here). Transport failure → `{:error, :media_unavailable}`
  (gateway → 503). Base URL from `MEDIA_SERVICE_URL`.
  """

  @behaviour SharedInfra.MediaClient

  @unavailable :media_unavailable

  @impl true
  def create_upload(attrs), do: post("/internal/media/create_upload", attrs)

  @impl true
  def complete_upload(attrs), do: post("/internal/media/complete_upload", attrs)

  @impl true
  def get_download_url(attrs), do: post("/internal/media/download_url", attrs)

  defp post(path, attrs) do
    SharedInfra.HttpClient.post_result(base_url(), path, attrs, unavailable: @unavailable)
  end

  defp base_url do
    Application.get_env(:shared_infra, :media_service_url) ||
      System.get_env("MEDIA_SERVICE_URL") || "http://localhost:4105"
  end
end

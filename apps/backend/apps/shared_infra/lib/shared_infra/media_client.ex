defmodule SharedInfra.MediaClient do
  @moduledoc """
  Client boundary for the Media service — lets edge apps stop calling `MediaService.*`
  in-process directly. Last of the client-boundary set (Auth/Conversation/User/Message/Media).

  Same pattern as the other `SharedInfra.*Client`s: behaviour AND configured dispatcher.
  Adapter from `:shared_infra, :media_client_adapter` (config default
  `MediaService.MediaClientInProcess`, delegates in-process → zero behavior change). A future
  `MEDIA_CLIENT_ADAPTER=http` selects an HTTP adapter (separate media-service container) WITHOUT
  touching call sites. shared_infra resolves the adapter from config at runtime, so it stays
  free of a service dependency.
  """

  @type attrs :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @callback create_upload(attrs()) :: result()
  @callback complete_upload(attrs()) :: result()
  @callback get_download_url(attrs()) :: result()
  @callback get_asset(attrs()) :: result()
  # Purge an asset's bytes (status sweep / owner delete). Optional so existing stubs don't need it.
  @callback purge_asset(attrs()) :: result()
  @optional_callbacks purge_asset: 1

  def create_upload(attrs), do: adapter().create_upload(attrs)
  def complete_upload(attrs), do: adapter().complete_upload(attrs)
  def get_download_url(attrs), do: adapter().get_download_url(attrs)
  # Read-path authz metadata (purpose/owner/conversation) by (media_id, app_id); never returns object_key.
  def get_asset(attrs), do: adapter().get_asset(attrs)
  def purge_asset(attrs), do: adapter().purge_asset(attrs)

  @doc "The configured Media client adapter (default `MediaService.MediaClientInProcess`)."
  def adapter do
    Application.get_env(:shared_infra, :media_client_adapter, MediaService.MediaClientInProcess)
  end
end

defmodule MediaService.MediaClientInProcess do
  @moduledoc """
  In-process adapter for `SharedInfra.MediaClient` — the default. Delegates straight to the
  existing `MediaService.Media` functions, returning the SAME shapes, so routing edge apps
  through the client boundary is a zero-behavior-change refactor. A future HTTP adapter
  (separate media-service container) implements the same behaviour.
  """

  @behaviour SharedInfra.MediaClient

  alias MediaService.Media

  @impl true
  def create_upload(attrs), do: Media.create_upload(attrs)

  @impl true
  def complete_upload(attrs), do: Media.complete_upload(attrs)

  @impl true
  def get_download_url(attrs), do: Media.get_download_url(attrs)

  @impl true
  def get_asset(attrs), do: Media.get_asset(attrs)

  @impl true
  def purge_asset(attrs), do: Media.purge_asset(attrs)

  @impl true
  def create_multipart_upload(attrs), do: MediaService.Media.create_multipart_upload(attrs)

  @impl true
  def presign_upload_parts(attrs), do: MediaService.Media.presign_upload_parts(attrs)

  @impl true
  def complete_multipart_upload(attrs), do: MediaService.Media.complete_multipart_upload(attrs)

  @impl true
  def abort_multipart_upload(attrs), do: MediaService.Media.abort_multipart_upload(attrs)
end

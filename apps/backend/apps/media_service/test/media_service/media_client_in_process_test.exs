defmodule MediaService.MediaClientInProcessTest do
  @moduledoc """
  Sanity that the default `SharedInfra.MediaClient` adapter delegates FAITHFULLY to
  `MediaService.Media` — same input, same result (the zero-behavior-change guarantee). Plain,
  Docker-free. Uses deterministic error paths (missing attrs fail before any UUID/URL
  generation), so the client result must equal the direct call exactly. media_service has no Repo.
  """
  use ExUnit.Case, async: true

  test "default adapter is the in-process adapter" do
    assert SharedInfra.MediaClient.adapter() == MediaService.MediaClientInProcess
  end

  test "create_upload through the client == calling MediaService.Media directly (deterministic error path)" do
    attrs = %{}
    assert SharedInfra.MediaClient.create_upload(attrs) == MediaService.Media.create_upload(attrs)
  end

  test "get_download_url through the client == MediaService.Media directly (deterministic error path)" do
    attrs = %{}
    assert SharedInfra.MediaClient.get_download_url(attrs) == MediaService.Media.get_download_url(attrs)
  end

  test "complete_upload through the client == MediaService.Media directly (deterministic error path)" do
    attrs = %{}
    assert SharedInfra.MediaClient.complete_upload(attrs) == MediaService.Media.complete_upload(attrs)
  end
end

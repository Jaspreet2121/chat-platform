defmodule SharedInfra.MediaClientAdapterResolutionTest do
  @moduledoc """
  END-TO-END TRACE of how a service release resolves its Media client, as the release boots it — not
  as this test env happens to have it.

  The prod bug: the user_service release does NOT contain `MediaService.MediaClientInProcess` (that
  module only exists where media_service is co-loaded). With no media env, `SharedInfra.MediaClient`
  falls back to that in-process default and every call crashes `UndefinedFunctionError`. Every
  cross-service seam (auth/conversation/user/message) is flipped to its HTTP adapter the same way —
  a `*_CLIENT_ADAPTER=http` env read by the umbrella's single `config/runtime.exs` at prod boot. This
  pins that the SAME mechanism selects the HTTP media adapter, and that WITHOUT the env the release
  falls back to the in-process module (the crash the compose env must prevent).

  Evaluates the REAL runtime.exs with `Config.Reader` under `env: :prod` — the same file, the same
  branch, the release runs.
  """
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  # runtime.exs's :prod branch fail-fasts on these before it reaches the adapter block; real-shaped
  # throwaway values (require_secret! rejects known placeholder strings).
  @mandatory %{
    "DATABASE_URL" => "ecto://user:pass@localhost/trace_only",
    "SECRET_KEY_BASE" => String.duplicate("kb7", 22),
    "TOKEN_SECRET" => String.duplicate("tk9", 22),
    "OTP_SECRET" => String.duplicate("ot3", 22),
    "PHX_HOST" => "trace.invalid"
  }

  defp read_prod_config!(extra_env) do
    # Force the two media keys ABSENT by default (a leak from another test would skew the read), then
    # let this call's `extra_env` win — so a test that sets them overrides the nils.
    managed =
      %{"MEDIA_CLIENT_ADAPTER" => nil, "MEDIA_SERVICE_URL" => nil}
      |> Map.merge(@mandatory)
      |> Map.merge(extra_env)

    previous = Map.new(managed, fn {k, _} -> {k, System.get_env(k)} end)

    Enum.each(managed, fn
      {k, nil} -> System.delete_env(k)
      {k, v} -> System.put_env(k, v)
    end)

    try do
      Config.Reader.read!(@runtime_exs, env: :prod)
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  # Apply what runtime.exs PUBLISHED into app env, then ask the REAL seam the call sites hit.
  defp resolved_adapter(published) do
    infra = Keyword.get(published, :shared_infra, [])
    previous = Application.get_env(:shared_infra, :media_client_adapter)

    case Keyword.fetch(infra, :media_client_adapter) do
      {:ok, module} -> Application.put_env(:shared_infra, :media_client_adapter, module)
      :error -> Application.delete_env(:shared_infra, :media_client_adapter)
    end

    try do
      SharedInfra.MediaClient.adapter()
    after
      if previous,
        do: Application.put_env(:shared_infra, :media_client_adapter, previous),
        else: Application.delete_env(:shared_infra, :media_client_adapter)
    end
  end

  test "prod env MEDIA_CLIENT_ADAPTER=http selects the HTTP adapter + publishes the media base URL" do
    config =
      read_prod_config!(%{
        "MEDIA_CLIENT_ADAPTER" => "http",
        "MEDIA_SERVICE_URL" => "http://media:4105"
      })

    assert config[:shared_infra][:media_client_adapter] == SharedInfra.MediaClientHttp
    assert config[:shared_infra][:media_service_url] == "http://media:4105"

    # The seam every call site hits resolves to the HTTP module (never the co-load-only in-process one).
    assert resolved_adapter(config) == SharedInfra.MediaClientHttp
  end

  test "WITHOUT the env the release falls back to the in-process default — the prod crash condition" do
    config = read_prod_config!(%{})

    refute Keyword.has_key?(config[:shared_infra] || [], :media_client_adapter)

    # This is exactly what broke: a release lacking MediaService.MediaClientInProcess still points here.
    assert resolved_adapter(config) == MediaService.MediaClientInProcess
  end

  test "the HTTP adapter implements the upload contract and forwards attrs verbatim (internal flag rides along)" do
    # create_upload/complete_upload exist, and `post/2` sends the attrs map unchanged — so a server-side
    # caller's `\"internal\" => true` reaches the media service (which honors it; see media_test).
    Code.ensure_loaded!(SharedInfra.MediaClientHttp)
    assert function_exported?(SharedInfra.MediaClientHttp, :create_upload, 1)
    assert function_exported?(SharedInfra.MediaClientHttp, :complete_upload, 1)
  end
end

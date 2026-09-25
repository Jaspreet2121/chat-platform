defmodule SharedInfra.ProdLogHygieneTest do
  @moduledoc """
  Production must not be one log-level change away from writing phone numbers to disk.

  Two lines carry phone numbers verbatim, and both are :debug: Phoenix's per-request `Parameters:`
  line (the contacts-sync body is up to 2,000 address-book numbers) and Ecto's query log (bound
  params, no filter of any kind). Prod logs at :info, so today neither is written — which is a
  configuration fact, not a code fact, and the privacy policy now states "not written to our logs"
  on the strength of it. This test evaluates the PROD config exactly as a release would and pins
  the three settings that make the sentence true even if somebody raises the level to debug at 2am.
  """
  use ExUnit.Case, async: true

  @config Path.expand("../../../../config/config.exs", __DIR__)

  @repos [
    auth_service: AuthService.Repo,
    user_service: UserService.Repo,
    conversation_service: ConversationService.Repo,
    message_service: MessageService.Repo,
    notification_service: NotificationService.Repo,
    media_service: MediaService.Repo
  ]

  # config.exs ends with `import_config "#{config_env()}.exs"`, so reading it as :prod pulls in
  # prod.exs — the same compile-time config a release is built with. runtime.exs is deliberately not
  # read: it needs real secrets in the environment, and it does not touch these keys.
  defp prod_config, do: Config.Reader.read!(@config, env: :prod)

  test "the phone keys are filtered out of Phoenix's request log" do
    filtered = prod_config()[:phoenix][:filter_parameters]

    for key <- ["phone_numbers", "phone_number", "phone"] do
      assert key in filtered, "#{inspect(key)} must be in :filter_parameters"
    end
  end

  test "Ecto query logging is OFF for every repo in prod" do
    config = prod_config()

    for {app, repo} <- @repos do
      assert config[app][repo][:log] == false,
             "#{inspect(repo)} must have log: false in prod — its query log prints bound params"
    end
  end

  test "prod logs at :info, so the debug-level lines are not written at all" do
    assert prod_config()[:logger][:level] == :info
  end

  test "runtime.exs's repo options MERGE into prod.exs, so log: false survives boot" do
    # Config.Provider applies runtime config with Config.Reader.merge/2 (deep keyword merge). If a
    # future Elixir replaced per-key instead, this is the test that would say so before a deploy did.
    compile_time = [auth_service: [{AuthService.Repo, [log: false]}]]
    runtime = [auth_service: [{AuthService.Repo, [url: "postgres://x", pool_size: 10]}]]

    merged = Config.Reader.merge(compile_time, runtime)
    assert merged[:auth_service][AuthService.Repo][:log] == false
    assert merged[:auth_service][AuthService.Repo][:url] == "postgres://x"
  end
end

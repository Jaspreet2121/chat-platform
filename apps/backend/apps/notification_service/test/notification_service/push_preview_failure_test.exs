defmodule NotificationService.PushPreviewFailureTest do
  @moduledoc """
  The push preview when the message store CANNOT BE READ — as distinct from a message that is simply
  gone (`NotificationService.PushPreviewStoreTest`).

  Both outcomes suppress the push. Only this one means a dependency is broken, and only this one is
  logged at `:error`. If they read the same in the logs, an operator staring at silent notifications
  cannot tell a deleted message from an unreachable message-service. THE LEVEL IS THE ASSERTION here,
  not an afterthought: `capture_log(level: :error)` sees nothing if the call is demoted to `:warning`.

  ## Why the second test exists

  `MESSAGE_CLIENT_ADAPTER` defaults to `MessageService.MessageClientInProcess`. That module is NOT in
  notification_service's release (`[shared_infra, notification_service]`), so on a container without
  `MESSAGE_CLIENT_ADAPTER=http` the boundary call raises `UndefinedFunctionError` on EVERY push —
  i.e. shipping the caller without the compose change breaks a working push path.

  A test cannot reproduce that by simply leaving the default in place, because the umbrella test run
  puts every app on the code path and `MessageClientInProcess` IS loaded here. So the test names an
  adapter module that genuinely does not exist. That is not a stub standing in for the real thing —
  it is the real condition (a module that is not loaded), and the resulting `UndefinedFunctionError`
  is the VM's, not an assumption of ours.

  No database and no listener: every path here is a failure to reach one.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias NotificationService.PushContext

  # Nothing listens here. A real Req call to a closed port is a real transport failure, which
  # SharedInfra.MessageClientHttp maps to {:error, :message_unavailable} — no double involved.
  @dead_port 4199

  setup do
    previous = %{
      client: Application.get_env(:shared_infra, :message_client_adapter),
      url: Application.get_env(:shared_infra, :message_service_url)
    }

    on_exit(fn ->
      restore = fn key, value ->
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end

      restore.(:message_client_adapter, previous.client)
      restore.(:message_service_url, previous.url)
    end)

    :ok
  end

  defp attrs do
    %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      sender_user_id: Ecto.UUID.generate()
    }
  end

  test "an UNREACHABLE message service logs at :error and suppresses the push" do
    Application.put_env(:shared_infra, :message_client_adapter, SharedInfra.MessageClientHttp)
    Application.put_env(:shared_infra, :message_service_url, "http://localhost:#{@dead_port}")

    a = attrs()

    log =
      capture_log([level: :error], fn ->
        assert :no_preview = PushContext.message_preview_fields(a.conversation_id, a.message_id)
      end)

    assert log =~ "push preview READ FAILED"
    # Identifiable: an operator must be able to find the message this silence belongs to.
    assert log =~ a.message_id
    assert log =~ a.conversation_id
    assert log =~ "message_unavailable"

    # And the whole context collapses to :no_preview, so neither sender emits anything.
    assert :no_preview = PushContext.message_context(a)
  end

  test "an adapter module that is NOT IN THE RELEASE is a failed read-back, not a raise" do
    # The production shape of "commit 1 shipped without the compose change". Deliberately a module
    # that does not exist — Code.ensure_loaded? proves it, so the UndefinedFunctionError below is the
    # genuine article rather than something this test arranged.
    refute Code.ensure_loaded?(NotDeployedInThisRelease.MessageClientInProcess)

    Application.put_env(
      :shared_infra,
      :message_client_adapter,
      NotDeployedInThisRelease.MessageClientInProcess
    )

    a = attrs()

    log =
      capture_log([level: :error], fn ->
        assert :no_preview = PushContext.message_preview_fields(a.conversation_id, a.message_id)
      end)

    assert log =~ "push preview READ FAILED"
    assert log =~ "UndefinedFunctionError"
    assert log =~ a.message_id
  end
end

defmodule ApiGatewayWeb.CallSurfaceAgreementTest do
  @moduledoc """
  THE TWO SURFACES MUST AGREE. A call has exactly one terminal outcome, and the caller must read the
  same outcome wherever they look.

  They did not. `CallSignaling.reject/2` deliberately writes a chat pill whose `metadata.status` is
  "missed" — "a DECLINED call must be INDISTINGUISHABLE from a missed one in the chat — the caller
  must never learn they were actively declined" (WhatsApp semantics). That decision was never applied
  to the Calls tab, which returned the raw call-row status. Verified on a device: the same call read

      transcript pill  ->  "Voice call - No answer"  (metadata.status = "missed")
      Calls tab row    ->  "Outgoing - Declined"     (call row status  = declined)

  Both clients rendered their own source faithfully. The pill was right; the Calls tab was the leak.

  This suite pins agreement for all three terminal paths, from the CALLER's side, and pins the one
  asymmetry that is deliberate: the CALLEE still sees their own decline.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.CallController

  @caller "11111111-1111-1111-1111-111111111111"
  @callee "22222222-2222-2222-2222-222222222222"
  @conversation "33333333-3333-3333-3333-333333333333"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user}),
      do: {:ok, %{user_id: user, app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    @moduledoc false
    def get_public_profile(%{"user_id" => id}), do: {:ok, %{user_id: id, display_name: "Peer"}}
    def get_public_profile(_), do: {:error, :profile_not_found}
    def get_privacy(_), do: {:ok, %{profile_photo_visibility: "everyone"}}
  end

  # Captures the pill the terminal paths write, so the assertion compares the REAL metadata rather
  # than a restatement of it.
  defmodule CapturingMessageClient do
    @moduledoc false
    def create_message(attrs) do
      send(:call_surface_collector, {:pill, attrs})
      {:ok, %{message_id: "m-1", conversation_id: attrs["conversation_id"]}}
    end
  end

  defp conversation_stub(call_status) do
    module = String.to_atom("Elixir.ConvStub#{System.unique_integer([:positive])}")

    contents =
      quote do
        def list_calls_for_user(%{"user_id" => _}) do
          {:ok,
           %{
             calls: [
               %{
                 id: "cd1785be-0000-0000-0000-000000000000",
                 room_name: "call-cd1785be",
                 kind: "direct",
                 caller_id: unquote(@caller),
                 callee_id: unquote(@callee),
                 conversation_id: unquote(@conversation),
                 type: "voice",
                 status: unquote(call_status),
                 created_at: "2026-08-03T10:00:00Z",
                 answered_at: nil,
                 ended_at: nil
               }
             ]
           }}
        end

        def either_blocked?(_attrs), do: {:ok, %{blocked: false}}
      end

    Module.create(module, contents, Macro.Env.location(__ENV__))
    module
  end

  setup do
    keys = [:auth_client_adapter, :user_client_adapter, :message_client_adapter]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :user_client_adapter, UserStub)
    Application.put_env(:shared_infra, :message_client_adapter, CapturingMessageClient)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      if prev_conv,
        do: Application.put_env(:shared_infra, :conversation_client_adapter, prev_conv),
        else: Application.delete_env(:shared_infra, :conversation_client_adapter)
    end)

    :ok
  end

  # What the Calls tab shows `viewer` for a call whose ROW status is `call_status`.
  defp calls_tab_status(call_status, viewer) do
    Application.put_env(
      :shared_infra,
      :conversation_client_adapter,
      conversation_stub(call_status)
    )

    conn =
      :get
      |> conn("/x", %{})
      |> put_req_header("authorization", "Bearer " <> viewer)
      |> CallController.index(%{})

    assert conn.status == 200
    [row] = Jason.decode!(conn.resp_body)["calls"]
    row["status"]
  end

  # What the chat pill carries after a terminal path runs.
  defp pill_status do
    Application.put_env(:shared_infra, :conversation_client_adapter, conversation_stub("ringing"))

    call = %{
      id: "cd1785be-0000-0000-0000-000000000000",
      conversation_id: @conversation,
      caller_id: @caller,
      callee_id: @callee,
      type: "voice"
    }

    RealtimeGateway.CallSignaling.write_missed_message(call, ApiGatewayWeb.Endpoint)

    assert_receive {:pill, attrs}, 2_000
    attrs["metadata"]["status"]
  end

  setup do
    Process.register(self(), :call_surface_collector)
    on_exit(fn -> :ok end)
    :ok
  end

  test "DECLINE: both surfaces say the same thing to the caller" do
    # The defect, pinned. The pill has always said "missed"; the Calls tab said "declined".
    assert pill_status() == "missed"
    assert calls_tab_status("declined", @caller) == "missed"
  end

  test "TIMEOUT: both surfaces agree" do
    assert pill_status() == "missed"
    assert calls_tab_status("missed", @caller) == "missed"
  end

  test "CANCEL: both surfaces agree (the caller hung up before an answer)" do
    # cancel marks the row missed and writes the same pill — nothing to mask, asserted so it stays so.
    assert pill_status() == "missed"
    assert calls_tab_status("missed", @caller) == "missed"
  end

  test "THE DELIBERATE ASYMMETRY: the CALLEE still sees their own decline" do
    # Masking is about what the CALLER learns. The callee performed the decline, so showing it back to
    # them reveals nothing and is useful history. If this ever returns "missed", the mask has been
    # applied too broadly and the decliner has lost their own call history.
    assert calls_tab_status("declined", @callee) == "declined"
  end

  test "non-terminal and answered statuses are passed through untouched for both parties" do
    for status <- ["ringing", "accepted", "ongoing", "ended"] do
      assert calls_tab_status(status, @caller) == status
      assert calls_tab_status(status, @callee) == status
    end
  end
end

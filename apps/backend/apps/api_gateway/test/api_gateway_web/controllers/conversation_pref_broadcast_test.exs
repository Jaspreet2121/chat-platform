defmodule ApiGatewayWeb.ConversationPrefBroadcastTest do
  @moduledoc """
  The debt fix: mute, clear-history and auto-delete now route through pref_mutation, so each emits the SAME
  conversation_updated `:pref` frame archive/pin emit — to the ACTING user only (their other devices go
  live; the peer hears nothing, a per-user pref is invisible to them). Same stub + assertion pattern as
  ConversationArchivePinTest. The post-clear frame ROW (preview/unread recomputed after cleared_before) is
  proven on real SQL in ConversationService.InboxRowsTest.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ConversationController

  @me "11111111-1111-4111-8111-111111111111"
  @peer "22222222-2222-4222-8222-222222222222"
  @conv "33333333-3333-4333-8333-333333333333"

  defmodule AuthStub do
    @me "11111111-1111-4111-8111-111111111111"
    def current_session(%{"authorization" => "Bearer me"}),
      do: {:ok, %{user_id: @me, app_id: "app1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    def set_mute(%{"conversation_id" => c}),
      do: {:ok, %{conversation_id: c, muted_until: "always"}}

    def clear_history(%{"conversation_id" => c}), do: {:ok, %{conversation_id: c, cleared: true}}

    def set_auto_delete(%{"conversation_id" => c}),
      do: {:ok, %{conversation_id: c, auto_delete: "24h"}}

    # TAGS (085) reuse the very same :pref path — a tag is per-user state exactly like mute/archive.
    def assign_tag(%{"conversation_id" => c, "tag_id" => t}),
      do: {:ok, %{conversation_id: c, tag_id: t, tagged: true}}

    def unassign_tag(%{"conversation_id" => c, "tag_id" => t}),
      do: {:ok, %{conversation_id: c, tag_id: t, tagged: false}}

    # The :pref broadcast (only: [me]) fetches the caller's own row.
    def inbox_rows(%{"conversation_id" => c, "user_ids" => uids}) do
      {:ok, %{rows: Enum.map(uids, &%{user_id: &1, conversation_id: c, unread_count: 0})}}
    end
  end

  setup do
    prev = %{
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      conv: Application.get_env(:shared_infra, :conversation_client_adapter)
    }

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      restore(:auth_client_adapter, prev.auth)
      restore(:conversation_client_adapter, prev.conv)
    end)

    # Listen on BOTH topics: the frame must reach the acting user and ONLY the acting user.
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@me}")
    Phoenix.PubSub.subscribe(ApiGateway.PubSub, "user:#{@peer}")
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp authed(method) do
    method |> conn("/x", %{}) |> put_req_header("authorization", "Bearer me")
  end

  defp assert_pref_to_me_only do
    assert_receive %Phoenix.Socket.Broadcast{event: "conversation_updated", topic: topic}, 1000
    assert topic == "user:#{@me}"
    # The peer's topic stays silent — a per-user pref is invisible to everyone else.
    refute_receive %Phoenix.Socket.Broadcast{event: "conversation_updated"}, 200
  end

  test "MUTE → 200 + :pref to the acting user ONLY (other devices unstale; peer hears nothing)" do
    conn =
      ConversationController.mute(authed(:put), %{"conversation_id" => @conv, "mode" => "always"})

    assert conn.status == 200
    assert_pref_to_me_only()
  end

  test "CLEAR-HISTORY → 200 + :pref to the acting user ONLY" do
    conn = ConversationController.clear(authed(:post), %{"conversation_id" => @conv})
    assert conn.status == 200
    assert_pref_to_me_only()
  end

  test "AUTO-DELETE → 200 + :pref to the acting user ONLY" do
    conn =
      ConversationController.auto_delete(authed(:put), %{
        "conversation_id" => @conv,
        "mode" => "24h",
        "scope" => "mine"
      })

    assert conn.status == 200
    assert_pref_to_me_only()
  end

  # A tag is per-user state, so its broadcast must behave exactly like the five prefs above: the
  # acting user's OTHER devices update live, and the peer — who cannot even see the tag exists —
  # hears nothing. This is what makes "reach other devices through the EXISTING machinery" true
  # rather than aspirational.
  @tag_id "44444444-4444-4444-8444-444444444444"

  test "ASSIGN TAG → 200 + :pref to the acting user ONLY (the peer never learns a tag exists)" do
    conn =
      ApiGatewayWeb.ConversationTagController.assign(authed(:put), %{
        "conversation_id" => @conv,
        "tag_id" => @tag_id
      })

    assert conn.status == 200
    assert_pref_to_me_only()
  end

  test "UNASSIGN TAG → 200 + :pref to the acting user ONLY" do
    conn =
      ApiGatewayWeb.ConversationTagController.unassign(authed(:delete), %{
        "conversation_id" => @conv,
        "tag_id" => @tag_id
      })

    assert conn.status == 200
    assert_pref_to_me_only()
  end
end

defmodule ApiGatewayWeb.MediaAuthzForwardTest do
  @moduledoc """
  FIX 4 — the security invariant behind the "forwarding re-uploads" decision (option b).

  Media download is authorized by membership of the conversation the asset was SENT to. `get_by_media_id`
  resolves that as the media_id's OLDEST message's conversation (oldest-wins) — which for a REUSED media_id is
  the SOURCE conversation, permanently. So when the web forwards media by reusing `source.media_id`, a
  recipient in the TARGET conversation (not the source) is correctly DENIED. That silent 404 is the reported
  bug AND the proof that forwarding must RE-UPLOAD a fresh asset scoped to the target (matching Android),
  never reuse the id.

  It also shows, by construction, why the alternative — widen authz to ANY conversation referencing the
  media_id — is UNSAFE: the first-party message-send path does not validate media ownership, so a user could
  plant a reference to someone else's media_id in a conversation they control and self-authorize. Narrow authz
  (proven here) is robust to that; widening is not. Choose the correct fix, not the smaller one.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.MediaAuthz

  @reused_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @fresh_media "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  @unsent_media "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

  @bob "33333333-3333-4333-8333-333333333333"
  @carol "44444444-4444-4444-8444-444444444444"
  @owner "55555555-5555-4555-8555-555555555555"

  # get_by_media_id models oldest-wins: the reused id resolves to the SOURCE conversation forever; a fresh id
  # (a re-upload) resolves to the TARGET; an unsent id resolves to no conversation.
  defmodule MsgStub do
    @reused "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    @fresh "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    @source_conv "11111111-1111-4111-8111-111111111111"
    @target_conv "22222222-2222-4222-8222-222222222222"

    def get_by_media_id(%{"media_id" => @reused}), do: {:ok, %{conversation_id: @source_conv}}
    def get_by_media_id(%{"media_id" => @fresh}), do: {:ok, %{conversation_id: @target_conv}}
    # Unsent (uploaded, never attached to a message) → no conversation.
    def get_by_media_id(_), do: {:error, :not_found}
  end

  # Membership: Bob ∈ SOURCE, Carol ∈ TARGET. No one is in both; anyone else → not a member.
  defmodule ConvStub do
    @source_conv "11111111-1111-4111-8111-111111111111"
    @target_conv "22222222-2222-4222-8222-222222222222"
    @bob "33333333-3333-4333-8333-333333333333"
    @carol "44444444-4444-4444-8444-444444444444"

    def get_conversation(%{"conversation_id" => @source_conv, "user_id" => @bob}), do: {:ok, %{}}
    def get_conversation(%{"conversation_id" => @target_conv, "user_id" => @carol}), do: {:ok, %{}}
    def get_conversation(_), do: {:error, :not_a_member}
  end

  setup do
    prev_msg = Application.get_env(:shared_infra, :message_client_adapter)
    prev_conv = Application.get_env(:shared_infra, :conversation_client_adapter)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)

    on_exit(fn ->
      restore(:message_client_adapter, prev_msg)
      restore(:conversation_client_adapter, prev_conv)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:shared_infra, key)
  defp restore(key, value), do: Application.put_env(:shared_infra, key, value)

  defp message_asset, do: %{purpose: "message", owner_user_id: @owner}

  test "the original recipient (a source-conversation member) CAN download the asset" do
    assert :ok = MediaAuthz.authorize_download(@reused_media, message_asset(), @bob)
  end

  test "THE BUG: a forward-recipient outside the source conversation is DENIED when the media_id is REUSED" do
    # Carol is a member of the TARGET conversation (where the forward landed), but the reused media_id still
    # authorizes against the SOURCE conversation (oldest-wins), which she isn't in → the silent coarse 404.
    # This is precisely why reuse cannot work and forwarding must re-upload.
    #
    # It is ALSO the security fact: widening authz to "any conversation referencing the media_id" would flip
    # this to :ok and let a member of a later conversation reach an asset first shared elsewhere — an IDOR,
    # because the send path never checks that the referencer may attach that media_id.
    assert {:error, :not_a_member} = MediaAuthz.authorize_download(@reused_media, message_asset(), @carol)
  end

  test "THE FIX: after re-upload, the forward-recipient CAN download the fresh asset (scoped to the target)" do
    # A fresh media_id whose only message is in the target conversation → Carol, a member there, is authorized.
    # This is the state option (b) produces: re-upload owned by the forwarder, scoped to the destination.
    assert :ok = MediaAuthz.authorize_download(@fresh_media, message_asset(), @carol)
  end

  test "an UNSENT asset (uploaded, not attached to any message) is owner-only" do
    assert :ok = MediaAuthz.authorize_download(@unsent_media, message_asset(), @owner)
    assert {:error, :not_a_member} = MediaAuthz.authorize_download(@unsent_media, message_asset(), @carol)
  end
end

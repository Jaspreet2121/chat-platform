defmodule ApiGatewayWeb.MediaAuthzForwardTest do
  @moduledoc """
  The OWNER-ANCHORED download rule (replacing oldest-message-wins, which authorized a reused media_id
  against exactly ONE conversation and broke BROADCASTS for recipients 2..N):

      allowed(viewer) = viewer IS the asset's owner
                        OR viewer is an active member of ANY conversation containing a message
                           referencing this media_id whose SENDER IS THE OWNER

  The anchor is what makes the widening safe: message-create does NOT validate media ownership
  (verified — only presence is checked), so B CAN plant a reference to A's media_id in B↔C. Under the
  anchored rule that planted message qualifies nobody — the leak case stays denied.

  WHAT IT DOES *NOT* FIX (do not remove a client workaround on the strength of this rule): forwarding
  media SOMEONE ELSE SENT YOU still fails. A uploads M, sends it in A↔B; B forwards to C reusing M; C
  qualifies only through a conversation where *A* sent M, and A only sent it to A↔B — C is DENIED.
  Only forwarding YOUR OWN media works. RE-UPLOAD-ON-FORWARD REMAINS REQUIRED for received media —
  Android does it, and apps/web does it unconditionally (reuploadMediaForForward, landed a31bf35);
  the "own media" case is the only one where it is now merely belt-and-braces.

  The stub is the message-service oracle; the REAL EXISTS (index, the planted-reference leak on actual
  rows, deleted-message semantics, the query count) is proven on SQL in
  MessageService.MediaDownloadAllowedTest.
  """
  use ExUnit.Case, async: false

  alias ApiGatewayWeb.MediaAuthz

  @owner "55555555-5555-4555-8555-555555555555"
  @bob "33333333-3333-4333-8333-333333333333"
  @carol "44444444-4444-4444-8444-444444444444"
  @uninvolved "66666666-6666-4666-8666-666666666666"

  # A's asset, fanned by A into A↔bob AND A↔carol (a broadcast / an owner-forward).
  @shared_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  # A's asset, uploaded but never sent.
  @unsent_media "cccccccc-cccc-4ccc-8ccc-cccccccccccc"

  defmodule MsgStub do
    @owner "55555555-5555-4555-8555-555555555555"
    @bob "33333333-3333-4333-8333-333333333333"
    @carol "44444444-4444-4444-8444-444444444444"
    @shared_media "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    # The oracle: bob and carol each sit in a conversation holding the OWNER'S send of the shared
    # asset → allowed. Everyone else (incl. someone reachable only through a NON-owner's planted
    # reference — the anchor filters those messages out) → denied.
    def media_download_allowed(%{
          "media_id" => @shared_media,
          "owner_user_id" => @owner,
          "viewer_user_id" => viewer
        })
        when viewer in [@bob, @carol],
        do: {:ok, %{allowed: true}}

    def media_download_allowed(_attrs), do: {:ok, %{allowed: false}}
  end

  defmodule DownStub do
    def media_download_allowed(_attrs), do: {:error, :message_unavailable}
  end

  setup do
    prev = Application.get_env(:shared_infra, :message_client_adapter)
    Application.put_env(:shared_infra, :message_client_adapter, MsgStub)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :message_client_adapter, prev),
        else: Application.delete_env(:shared_infra, :message_client_adapter)
    end)

    :ok
  end

  defp asset(media_id), do: %{media_id: media_id, purpose: "message", owner_user_id: @owner}

  test "BROADCAST / OWNER-FORWARD: every recipient of the owner's sends can download the ONE shared asset" do
    assert :ok = MediaAuthz.authorize_download(@shared_media, asset(@shared_media), @bob)
    assert :ok = MediaAuthz.authorize_download(@shared_media, asset(@shared_media), @carol)
  end

  test "the OWNER always may (fast-path — no message lookup), including for an UNSENT asset" do
    assert :ok = MediaAuthz.authorize_download(@shared_media, asset(@shared_media), @owner)
    assert :ok = MediaAuthz.authorize_download(@unsent_media, asset(@unsent_media), @owner)
  end

  test "an uninvolved user is DENIED — a non-owner's planted reference grants nobody anything" do
    assert {:error, :not_a_member} =
             MediaAuthz.authorize_download(@shared_media, asset(@shared_media), @uninvolved)
  end

  test "an UNSENT asset stays owner-only" do
    assert {:error, :not_a_member} =
             MediaAuthz.authorize_download(@unsent_media, asset(@unsent_media), @bob)
  end

  test "message-service outage fails CLOSED (unavailable, never a silent allow)" do
    Application.put_env(:shared_infra, :message_client_adapter, DownStub)

    assert {:error, :conversation_unavailable} =
             MediaAuthz.authorize_download(@shared_media, asset(@shared_media), @bob)
  end
end

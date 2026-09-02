defmodule ApiGatewayWeb.ViewOnceCreateTest do
  @moduledoc """
  Where view_once is REFUSED at create (115), Docker-free.

  Two refusals, both loud rather than silent, because a silently-dropped view_once means the sender
  believes they sent a disappearing message and is wrong — the one failure mode this feature must
  never have.
  """
  use ExUnit.Case, async: true

  alias MessageService.Messages

  defp media_attrs(extra) do
    Map.merge(
      %{
        "conversation_id" => "11111111-1111-4111-8111-111111111111",
        "sender_user_id" => "22222222-2222-4222-8222-222222222222",
        "message_type" => "media",
        "media_id" => "33333333-3333-4333-8333-333333333333"
      },
      extra
    )
  end

  describe "view_once is valid ONLY on a media message" do
    test "a TEXT message with view_once is refused" do
      attrs = media_attrs(%{"message_type" => "text", "body" => "hi", "view_once" => true})

      assert {:error, :view_once_invalid} = Messages.create_message(attrs)
    end

    test "a SEALED message with view_once is refused" do
      # media_id is forced nil for sealed (the descriptor rides inside the ciphertext), so the server
      # could never find the blob to delete. Refused rather than accepted and silently unenforceable.
      attrs =
        media_attrs(%{
          "message_type" => "sealed",
          "view_once" => true,
          "metadata" => %{"sealed" => %{"v" => 1}}
        })

      assert {:error, :view_once_invalid} = Messages.create_message(attrs)
    end

    test "the string \"true\" is refused on a non-media type too (JSON clients send strings)" do
      attrs = media_attrs(%{"message_type" => "text", "body" => "hi", "view_once" => "true"})

      assert {:error, :view_once_invalid} = Messages.create_message(attrs)
    end
  end

  describe "absent or falsy view_once is always fine — INERTNESS" do
    test "a text message without the flag is untouched" do
      attrs = media_attrs(%{"message_type" => "text", "body" => "hi"})

      refute match?({:error, :view_once_invalid}, Messages.create_message(attrs))
    end

    test "an explicit false on a text message is not a refusal" do
      attrs = media_attrs(%{"message_type" => "text", "body" => "hi", "view_once" => false})

      refute match?({:error, :view_once_invalid}, Messages.create_message(attrs))
    end

    test "junk in the field reads as false, never as a refusal" do
      for junk <- [nil, "", 0, "yes", %{}] do
        attrs = media_attrs(%{"message_type" => "text", "body" => "hi", "view_once" => junk})

        refute match?({:error, :view_once_invalid}, Messages.create_message(attrs)),
               "#{inspect(junk)} must read as false"
      end
    end
  end
end

defmodule ApiGatewayWeb.ViewOnceBroadcastTest do
  @moduledoc """
  Broadcast REFUSES view_once (115) rather than dropping it.

  One media_id fans to N conversations, each needing its own per-recipient open — but the FIRST open
  deletes the blob for everyone, so recipients 2..N would silently lose a message they were told they
  had. @message_fields would have dropped the flag quietly, which is worse: the sender would believe
  they sent view-once and be wrong.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  @opts ApiGatewayWeb.Router.init([])

  defp send_broadcast(params) do
    :post
    |> conn("/api/v1/broadcasts/11111111-1111-4111-8111-111111111111/send", params)
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer someone")
    |> ApiGatewayWeb.Router.call(@opts)
  end

  test "view_once on a broadcast is refused 422, before any auth or fan-out work" do
    conn = send_broadcast(%{"message_type" => "media", "media_id" => "m1", "view_once" => true})

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "broadcast.view_once_unsupported"
  end

  test "the string form is refused too" do
    conn = send_broadcast(%{"message_type" => "media", "media_id" => "m1", "view_once" => "true"})

    assert conn.status == 422
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "broadcast.view_once_unsupported"
  end

  test "an ordinary broadcast is NOT refused by this rule" do
    # It fails later (no session), but never with view_once_unsupported — the rule must not widen.
    conn = send_broadcast(%{"message_type" => "media", "media_id" => "m1"})

    refute Jason.decode!(conn.resp_body)["error"]["code"] == "broadcast.view_once_unsupported"
  end
end

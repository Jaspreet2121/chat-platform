defmodule ApiGatewayWeb.ConversationShowPinsTest do
  @moduledoc """
  PINNED MESSAGES ON THE CONVERSATION DETAIL RESPONSE.

  The pin/unpin endpoints and the dedicated GET /pins shipped in b6a79d9, but pins were never wired
  into `:show` — so the key the client contract documents on the detail response never appeared.
  Production had four pin rows and no client had ever rendered a pinned bar.

  The assertion that matters most here is not that the key exists. It is that the key is MASKED
  PER VIEWER: two people in the same conversation can legitimately receive different pinned bars,
  because a pin must never resurrect a message the viewer cleared, that auto-deleted for them, or
  that they deleted for themselves. Wiring pins in without the mask would have been a privacy
  regression, not a missing feature.
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.ConversationController

  @conversation "0f8b1d99-4f06-4dbe-9a52-3c0f4d9fef03"
  @sees "11111111-1111-1111-1111-111111111111"
  @cleared "22222222-2222-2222-2222-222222222222"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer " <> user}),
      do: {:ok, %{user_id: user, app_id: "app-1"}}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule ConvStub do
    @moduledoc false
    def get_conversation(%{"conversation_id" => id}),
      do: {:ok, %{conversation_id: id, type: "group", title: "Team"}}
  end

  # Stands in for MessageService.Pins over the client boundary. The MASK is modelled the way the real
  # query masks it: the pin is withheld from a viewer who cleared it. `@cleared` is that viewer.
  defmodule PinsStub do
    @moduledoc false
    def list_pins(%{"conversation_id" => _, "user_id" => user}) do
      pins =
        if user == "22222222-2222-2222-2222-222222222222" do
          []
        else
          [
            %{
              message_id: "aaaaaaaa-0000-0000-0000-000000000001",
              pinned_by: "11111111-1111-1111-1111-111111111111",
              pinned_at: "2026-08-04T14:10:00Z"
            }
          ]
        end

      {:ok, %{pins: pins}}
    end
  end

  defmodule PinsFailingStub do
    @moduledoc false
    def list_pins(_attrs), do: {:error, :message_unavailable}
  end

  # The shape that actually bit: Pins.list_pins/1 reaches Postgres via Repo.query!, which RAISES.
  # A `case` on the return value never sees it.
  defmodule PinsRaisingStub do
    @moduledoc false
    def list_pins(_attrs),
      do: raise(RuntimeError, "could not lookup Ecto repo MessageService.Repo")
  end

  setup do
    keys = [:auth_client_adapter, :conversation_client_adapter, :message_client_adapter]
    prev = for k <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    prev_persist = Application.get_env(:conversation_service, :conversation_persistence)

    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :conversation_client_adapter, ConvStub)
    Application.put_env(:shared_infra, :message_client_adapter, PinsStub)
    Application.put_env(:conversation_service, :conversation_persistence, true)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end

      if prev_persist,
        do: Application.put_env(:conversation_service, :conversation_persistence, prev_persist),
        else: Application.delete_env(:conversation_service, :conversation_persistence)
    end)

    :ok
  end

  defp show(viewer) do
    conn =
      :get
      |> conn("/x", %{})
      |> put_req_header("authorization", "Bearer " <> viewer)
      |> ConversationController.show(%{"conversation_id" => @conversation})

    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  test "(a) :show returns pinned_messages for a conversation that has pins" do
    body = show(@sees)

    assert Map.has_key?(body, "pinned_messages"),
           "the detail response must carry pinned_messages — its absence is the bug being fixed"

    assert length(body["pinned_messages"]) == 1
  end

  test "(b) THE PRIVACY ASSERTION: a viewer who cleared the pinned message does not receive it" do
    # Same conversation, same instant, two viewers, different pinned bars. That is intended: a pin is
    # per-conversation but cleared_before / auto-delete / hidden markers are per-user, and a pin
    # overrides none of them.
    assert [_one] = show(@sees)["pinned_messages"]

    assert show(@cleared)["pinned_messages"] == [],
           "a pin must never resurrect a message this viewer cleared"
  end

  test "(b2) the VIEWER is what gets passed — not a nil that would take the unmasked path" do
    # Pins.list_pins/1 returns the conversation's pins UNMASKED when the viewer is nil or "".
    # If :show ever stopped passing the session user, every viewer would receive every pin — the
    # privacy regression would be silent and would look like the feature working.
    parent = self()

    defmodule ViewerCapturingStub do
      @moduledoc false
      def list_pins(%{"user_id" => user} = attrs) do
        send(:conversation_show_pins_collector, {:viewer, user, attrs["conversation_id"]})
        {:ok, %{pins: []}}
      end
    end

    Process.register(parent, :conversation_show_pins_collector)
    Application.put_env(:shared_infra, :message_client_adapter, ViewerCapturingStub)

    show(@sees)

    assert_received {:viewer, @sees, @conversation}
    Process.unregister(:conversation_show_pins_collector)
  end

  test "(c) FAILURE MODE: pins failing OMITS the key and never fails the detail response" do
    Application.put_env(:shared_infra, :message_client_adapter, PinsFailingStub)

    body = show(@sees)

    # Chat open must survive a pins outage — the response is still a 200 with the conversation.
    assert body["conversation_id"] == @conversation

    # And the key is ABSENT, not an empty array. `[]` would assert "this conversation has no pins",
    # which may be false; absent says "we did not answer". Android cannot tell the two apart today,
    # but the server must not destroy the distinction.
    refute Map.has_key?(body, "pinned_messages")
  end

  test "(c2) FAILURE MODE: a RAISING pins lookup also omits the key and keeps chat open" do
    # This is the case the error-tuple test above did NOT cover, and it is the realistic one: the pins
    # read goes through Repo.query!, so an unstarted repo or a connection error arrives as an
    # exception, not as {:error, _}. Before the rescue, this took the entire detail response down —
    # found by the wider suite (MediaAvatarPresignTest), not by this file.
    Application.put_env(:shared_infra, :message_client_adapter, PinsRaisingStub)

    body = show(@sees)

    assert body["conversation_id"] == @conversation
    refute Map.has_key?(body, "pinned_messages")
  end

  test "(d) WIRE SHAPE: exact key and field names the client contract documents" do
    body = show(@sees)

    assert [pin] = body["pinned_messages"]

    # Field-for-field against ANDROID_API_CONTRACT.md §6.1: {message_id, pinned_by, pinned_at}.
    # Two clients are built against these names; a rename here is a silent client break.
    assert Map.keys(pin) |> Enum.sort() == ["message_id", "pinned_at", "pinned_by"]
    assert is_binary(pin["message_id"])
    assert is_binary(pin["pinned_by"])
    assert is_binary(pin["pinned_at"])
  end
end

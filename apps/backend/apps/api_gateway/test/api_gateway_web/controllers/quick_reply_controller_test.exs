defmodule ApiGatewayWeb.QuickReplyControllerTest do
  @moduledoc """
  The gateway half of quick replies + built-in commands (100), no DB: reserved names 409, media
  ownership 422, the changed-broadcast on every successful mutation, the 30/min write limit, and
  the cacheable commands endpoint (shape + ETag 304).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.{CommandController, QuickReplyController}

  @user "11111111-1111-1111-1111-111111111111"
  @app "44444444-4444-4444-8444-444444444444"

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer me"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-1111-1111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444",
           device_id: "web-1"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    @moduledoc false
    def create_quick_reply(attrs) do
      send(:quick_reply_test, {:create, attrs})
      {:ok, %{id: "qr-1", shortcut: attrs["shortcut"], body: attrs["body"], position: 0}}
    end

    def list_quick_replies(_attrs), do: {:ok, %{quick_replies: [%{id: "qr-1", shortcut: "brb"}]}}
    def update_quick_reply(attrs), do: {:ok, %{id: attrs["id"], shortcut: attrs["shortcut"]}}
    def delete_quick_reply(attrs), do: {:ok, %{deleted: true, id: attrs["id"]}}
    def reorder_quick_replies(_attrs), do: {:ok, %{quick_replies: []}}
  end

  defmodule MediaStub do
    @moduledoc false
    # media "mine-1" belongs to the caller; anything else to someone else.
    def get_asset(%{"media_id" => "mine-1"}),
      do: {:ok, %{owner_user_id: "11111111-1111-1111-1111-111111111111"}}

    def get_asset(_attrs), do: {:ok, %{owner_user_id: "99999999-9999-9999-9999-999999999999"}}
  end

  defmodule LimiterOk do
    @moduledoc false
    def check_rate(_attrs), do: :ok
  end

  defmodule LimiterTrips do
    @moduledoc false
    def check_rate(_attrs), do: {:error, :rate_limited, 17}
  end

  setup do
    Process.register(self(), :quick_reply_test)

    keys = [
      auth_client_adapter: AuthStub,
      user_client_adapter: UserStub,
      media_client_adapter: MediaStub,
      rate_limiter_adapter: LimiterOk
    ]

    prev = for {k, _} <- keys, into: %{}, do: {k, Application.get_env(:shared_infra, k)}
    for {k, v} <- keys, do: Application.put_env(:shared_infra, k, v)

    on_exit(fn ->
      for {k, v} <- prev do
        if v,
          do: Application.put_env(:shared_infra, k, v),
          else: Application.delete_env(:shared_infra, k)
      end
    end)

    :ok
  end

  defp request(action, params, method \\ :post) do
    method
    |> conn("/x", params)
    |> put_req_header("authorization", "Bearer me")
    |> then(&QuickReplyController.call(&1, QuickReplyController.init(action)))
  end

  test "create: passes the session identity through, broadcasts quick_replies_changed" do
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @user)

    conn = request(:create, %{"shortcut" => "brb", "body" => "Be right back"})
    assert conn.status == 201

    assert_receive {:create, attrs}
    assert attrs["user_id"] == @user
    assert attrs["app_id"] == @app

    assert_receive %Phoenix.Socket.Broadcast{event: "quick_replies_changed"}
  end

  test "a RESERVED (built-in) shortcut → 409 quick_reply.reserved, and the store is never called" do
    for reserved <- ["qr", "pay", "location", "contact"] do
      conn = request(:create, %{"shortcut" => reserved, "body" => "x"})
      assert conn.status == 409
      assert %{"error" => %{"code" => "quick_reply.reserved"}} = Jason.decode!(conn.resp_body)
    end

    refute_receive {:create, _}, 50
  end

  test "an attached media the caller does NOT own → 422; an owned one passes" do
    conn = request(:create, %{"shortcut" => "menu", "body" => "x", "media_id" => "theirs-1"})
    assert conn.status == 422
    refute_receive {:create, _}, 50

    conn = request(:create, %{"shortcut" => "menu", "body" => "x", "media_id" => "mine-1"})
    assert conn.status == 201
    assert_receive {:create, %{"media_id" => "mine-1"}}
  end

  test "writes are rate-limited: 429 with Retry-After; reads are not" do
    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterTrips)

    conn = request(:create, %{"shortcut" => "brb", "body" => "x"})
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["17"]

    assert request(:index, %{}, :get).status == 200
  end

  test "GET /commands: the static shape, and If-None-Match → 304" do
    conn =
      :get
      |> conn("/api/v1/commands", %{})
      |> put_req_header("authorization", "Bearer me")
      |> then(&CommandController.call(&1, CommandController.init(:index)))

    assert conn.status == 200
    [etag] = get_resp_header(conn, "etag")

    %{"commands" => commands} = Jason.decode!(conn.resp_body)
    names = Enum.map(commands, & &1["name"])
    assert names == ~w(qr pay location address website email hours contact)

    qr = Enum.find(commands, &(&1["name"] == "qr"))

    assert qr == %{
             "name" => "qr",
             "kind" => "action",
             "label" => "Send my UPI QR",
             "requires" => "upi_id"
           }

    pay = Enum.find(commands, &(&1["name"] == "pay"))
    assert pay["template"] == "Pay me on UPI: {upi_id}"

    cached =
      :get
      |> conn("/api/v1/commands", %{})
      |> put_req_header("authorization", "Bearer me")
      |> put_req_header("if-none-match", etag)
      |> then(&CommandController.call(&1, CommandController.init(:index)))

    assert cached.status == 304
    assert cached.resp_body == ""
  end
end

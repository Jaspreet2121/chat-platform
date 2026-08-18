defmodule ApiGatewayWeb.LinkControllerTest do
  @moduledoc """
  The QR link flow (099), driven end-to-end through the controller with an in-memory LinkStore (the
  Redis seam): create → approve (phone session) → poll returns the tokens EXACTLY ONCE → consumed.
  Plus every refusal: expiry (410 / state expired), wrong nonce, replay (409), wrong poll_token
  (indistinguishable 404), missing confirm, malformed payload, per-user approve rate limit with
  Retry-After, and mint-failure fail-closed (503, state stays pending).
  """
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.LinkController

  @user "11111111-1111-1111-1111-111111111111"
  @app "44444444-4444-4444-8444-444444444444"

  defmodule MemStore do
    @moduledoc false
    @behaviour ApiGatewayWeb.LinkStore
    def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def reset, do: Agent.update(__MODULE__, fn _ -> %{} end)
    # TTL elapsed, simulated (the real store's expiry is Redis's).
    def expire(key), do: Agent.update(__MODULE__, &Map.delete(&1, key))

    @impl true
    def put(key, value, _ttl), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

    @impl true
    def get(key) do
      case Agent.get(__MODULE__, &Map.get(&1, key)) do
        nil -> :not_found
        value -> {:ok, value}
      end
    end

    @impl true
    def put_get(key, value, _ttl) do
      Agent.get_and_update(__MODULE__, fn state ->
        previous = Map.get(state, key)

        reply =
          if is_binary(previous), do: {:ok, {:was_present, previous}}, else: {:ok, :was_absent}

        {reply, Map.put(state, key, value)}
      end)
    end

    @impl true
    def del(key), do: Agent.update(__MODULE__, &Map.delete(&1, key))
  end

  defmodule AuthStub do
    @moduledoc false
    def current_session(%{"authorization" => "Bearer phone-session"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-1111-1111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444",
           device_id: "phone-1"
         }}

    def current_session(_), do: {:error, :session_invalid}

    def link_device_session(attrs) do
      send(:link_test_collector, {:mint, attrs})

      case Application.get_env(:api_gateway, :link_mint_result, :ok) do
        :ok ->
          {:ok,
           %{
             access_token: "at-secret",
             access_token_expires_in_seconds: 604_800,
             refresh_token: "rt-secret",
             refresh_token_expires_in_seconds: 2_592_000,
             session_id: "sess-1",
             device_id: "web-abc",
             device_name: attrs["device_name"]
           }}

        :error ->
          {:error, :link_invalid}
      end
    end
  end

  defmodule LimiterOk do
    @moduledoc false
    def check_rate(_attrs), do: :ok
  end

  defmodule LimiterTrips do
    @moduledoc false
    def check_rate(_attrs), do: {:error, :rate_limited, 42}
  end

  setup do
    start_supervised!(%{id: MemStore, start: {MemStore, :start_link, []}})
    MemStore.reset()
    Process.register(self(), :link_test_collector)

    prev = %{
      store: Application.get_env(:api_gateway, :link_store_adapter),
      auth: Application.get_env(:shared_infra, :auth_client_adapter),
      limiter: Application.get_env(:shared_infra, :rate_limiter_adapter),
      window: Application.get_env(:api_gateway, :link_poll_window_ms),
      interval: Application.get_env(:api_gateway, :link_poll_interval_ms)
    }

    Application.put_env(:api_gateway, :link_store_adapter, MemStore)
    Application.put_env(:shared_infra, :auth_client_adapter, AuthStub)
    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterOk)
    # Shrink the long-poll so pending polls return fast in tests.
    Application.put_env(:api_gateway, :link_poll_window_ms, 120)
    Application.put_env(:api_gateway, :link_poll_interval_ms, 20)

    on_exit(fn ->
      restore(:api_gateway, :link_store_adapter, prev.store)
      restore(:shared_infra, :auth_client_adapter, prev.auth)
      restore(:shared_infra, :rate_limiter_adapter, prev.limiter)
      restore(:api_gateway, :link_poll_window_ms, prev.window)
      restore(:api_gateway, :link_poll_interval_ms, prev.interval)
      Application.delete_env(:api_gateway, :link_mint_result)
    end)

    :ok
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp create! do
    conn = conn(:post, "/api/v1/link/qr", %{}) |> LinkController.create(%{})
    assert conn.status == 200
    Jason.decode!(conn.resp_body)
  end

  defp approve(qr_payload, opts \\ []) do
    params =
      %{"qr_payload" => qr_payload, "confirm" => true, "device_name" => "Chrome on Mac"}
      |> Map.merge(Keyword.get(opts, :params, %{}))

    :post
    |> conn("/api/v1/link/approve", params)
    |> put_req_header("authorization", "Bearer " <> Keyword.get(opts, :session, "phone-session"))
    |> LinkController.approve(params)
  end

  defp poll(link_id, poll_token) do
    params = %{"link_id" => link_id, "poll_token" => poll_token}
    conn(:get, "/x", params) |> LinkController.wait(params)
  end

  test "HAPPY PATH: create → approve → poll returns the session EXACTLY ONCE → consumed" do
    created = create!()
    assert String.starts_with?(created["qr_payload"], "skifi-link:v1:")
    assert created["expires_in"] == 60
    assert is_binary(created["poll_token"]) and is_binary(created["link_id"])

    # The phone's Linked-devices screen gets the live event.
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @user)

    approved = approve(created["qr_payload"])
    assert approved.status == 200
    assert %{"linked" => true, "session_id" => "sess-1"} = Jason.decode!(approved.resp_body)

    # The mint carried the PHONE's identity: its user, its tenant, its device as linker.
    assert_receive {:mint, mint_attrs}
    assert mint_attrs["user_id"] == @user
    assert mint_attrs["app_id"] == @app
    assert mint_attrs["linked_by_device_id"] == "phone-1"

    assert_receive %Phoenix.Socket.Broadcast{event: "device_linked", payload: payload}
    assert payload.session_id == "sess-1"

    # The browser collects the tokens — once.
    first = poll(created["link_id"], created["poll_token"])
    assert first.status == 200

    assert %{"state" => "approved", "session" => session} = Jason.decode!(first.resp_body)
    assert session["access_token"] == "at-secret"
    assert session["refresh_token"] == "rt-secret"
    assert session["session_id"] == "sess-1"
    assert is_binary(session["expires_at"])

    # Second poll: consumed, no tokens, ever again.
    second = poll(created["link_id"], created["poll_token"])
    assert %{"state" => "consumed"} = Jason.decode!(second.resp_body)
    refute Jason.decode!(second.resp_body) |> Map.has_key?("session")
  end

  test "a pending link long-polls then reports pending; expiry reports expired" do
    created = create!()

    pending = poll(created["link_id"], created["poll_token"])
    assert %{"state" => "pending"} = Jason.decode!(pending.resp_body)

    MemStore.expire("link_qr:" <> created["link_id"])
    expired = poll(created["link_id"], created["poll_token"])
    assert %{"state" => "expired"} = Jason.decode!(expired.resp_body)
  end

  # A store that misbehaves in a rotating pattern — RAISES, then ERRORS, then works — so a sustained
  # poll crosses every failure mode several times. The wait contract: the browser NEVER sees a 5xx
  # for a still-resolvable link (2026-08-18 prod fix — 500s at ~16s killed live link attempts).
  defmodule FlakyStore do
    @moduledoc false
    @behaviour ApiGatewayWeb.LinkStore
    def start_link, do: Agent.start_link(fn -> 0 end, name: __MODULE__)

    @impl true
    def put(key, value, ttl), do: ApiGatewayWeb.LinkControllerTest.MemStore.put(key, value, ttl)

    @impl true
    def get(key) do
      case Agent.get_and_update(__MODULE__, fn n -> {n, n + 1} end) |> rem(3) do
        0 -> raise "boom (simulated store crash)"
        1 -> {:error, :closed}
        _ -> ApiGatewayWeb.LinkControllerTest.MemStore.get(key)
      end
    end

    @impl true
    def put_get(key, value, ttl),
      do: ApiGatewayWeb.LinkControllerTest.MemStore.put_get(key, value, ttl)

    @impl true
    def del(key), do: ApiGatewayWeb.LinkControllerTest.MemStore.del(key)
  end

  test "NEVER 5xx WHILE PENDING: a minute of polling through crashes and store errors is all 200s" do
    created = create!()

    start_supervised!(%{id: FlakyStore, start: {FlakyStore, :start_link, []}})
    Application.put_env(:api_gateway, :link_store_adapter, FlakyStore)

    # Tight loop for the test: the window/interval shrink makes ~20 polls stand in for 60s of real time.
    Application.put_env(:api_gateway, :link_poll_interval_ms, 10)

    on_exit(fn ->
      Application.put_env(:api_gateway, :link_store_adapter, MemStore)
      Application.delete_env(:api_gateway, :link_poll_interval_ms)
    end)

    for _ <- 1..20 do
      conn = poll(created["link_id"], created["poll_token"])
      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["state"] in ["pending", "approved"]
    end
  end

  test "a decrypt failure answers pending and does NOT consume the approved state" do
    created = create!()
    assert approve(created["qr_payload"]).status == 200

    # Corrupt the encrypted payload in place: valid base64, right envelope sizes, garbage AEAD bytes —
    # decrypt returns :error and the pipeline raises (the exact shape of the pre-fix 500-after-consume).
    store_key = "link_qr:" <> created["link_id"]
    {:ok, raw} = MemStore.get(store_key)
    state = Jason.decode!(raw)
    garbage = Base.encode64(:crypto.strong_rand_bytes(12 + 16 + 32))
    MemStore.put(store_key, Jason.encode!(%{state | "payload_enc" => garbage}), 60)

    conn = poll(created["link_id"], created["poll_token"])
    assert conn.status == 200
    assert %{"state" => "pending"} = Jason.decode!(conn.resp_body)

    # THE POINT: the single retrieval was NOT burned — the state is still approved, not consumed.
    {:ok, after_raw} = MemStore.get(store_key)
    assert %{"state" => "approved"} = Jason.decode!(after_raw)
  end

  test "a WRONG poll_token is indistinguishable from an unknown link (404), even when approved" do
    created = create!()
    assert approve(created["qr_payload"]).status == 200

    conn = poll(created["link_id"], "wrong-token")
    assert conn.status == 404

    # And the state was NOT consumed by the failed attempt — the real browser still gets its tokens.
    assert %{"state" => "approved"} =
             Jason.decode!(poll(created["link_id"], created["poll_token"]).resp_body)
  end

  test "wrong nonce → 400 invalid_payload, and the link stays pending (approvable by the real QR)" do
    created = create!()
    ["skifi-link", "v1", link_id, _nonce] = String.split(created["qr_payload"], ":")

    wrong = approve("skifi-link:v1:" <> link_id <> ":forged-nonce")
    assert wrong.status == 400
    assert %{"error" => %{"code" => "link.invalid_payload"}} = Jason.decode!(wrong.resp_body)

    assert approve(created["qr_payload"]).status == 200
  end

  test "replaying an approve → 409 already_used; approving an expired link → 410" do
    created = create!()
    assert approve(created["qr_payload"]).status == 200

    replay = approve(created["qr_payload"])
    assert replay.status == 409
    assert %{"error" => %{"code" => "link.already_used"}} = Jason.decode!(replay.resp_body)

    fresh = create!()
    MemStore.expire("link_qr:" <> fresh["link_id"])
    gone = approve(fresh["qr_payload"])
    assert gone.status == 410
    assert %{"error" => %{"code" => "link.expired"}} = Jason.decode!(gone.resp_body)
  end

  test "malformed payload / missing confirm / no session are each refused" do
    created = create!()

    assert approve("not-a-qr-payload").status == 400
    assert approve(created["qr_payload"], params: %{"confirm" => false}).status == 400
    assert approve(created["qr_payload"], session: "nope").status == 401
  end

  test "MINT FAILURE FAILS CLOSED: 503, and the link stays pending (no half-approved state)" do
    created = create!()
    Application.put_env(:api_gateway, :link_mint_result, :error)

    assert approve(created["qr_payload"]).status == 503

    assert %{"state" => "pending"} =
             Jason.decode!(poll(created["link_id"], created["poll_token"]).resp_body)
  end

  test "approve is rate-limited per user: 429 with Retry-After" do
    created = create!()
    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterTrips)

    conn = approve(created["qr_payload"])
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["42"]
    assert %{"error" => %{"code" => "link.rate_limited"}} = Jason.decode!(conn.resp_body)
  end
end

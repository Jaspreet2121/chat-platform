defmodule ApiGatewayWeb.NearbyControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias ApiGatewayWeb.NearbyController

  @me "11111111-1111-1111-1111-111111111111"
  @peer "22222222-2222-2222-2222-222222222222"
  @app "44444444-4444-4444-8444-444444444444"
  @request "55555555-5555-4555-8555-555555555555"

  defmodule AuthStub do
    def current_session(%{"authorization" => "Bearer token"}),
      do:
        {:ok,
         %{
           user_id: "11111111-1111-1111-1111-111111111111",
           app_id: "44444444-4444-4444-8444-444444444444"
         }}

    def current_session(_), do: {:error, :session_invalid}
  end

  defmodule UserStub do
    def discover_nearby(attrs) do
      send(:nearby_test_collector, {:discover, attrs})

      people =
        Application.get_env(:api_gateway, :test_nearby_people, [
          %{
            user_id: "22222222-2222-2222-2222-222222222222",
            distance_bucket_m: 100,
            relationship: "none"
          }
        ])

      {:ok, %{people: people, expires_in_seconds: 300, radius_m: attrs["radius_m"]}}
    end

    def stop_nearby(attrs) do
      send(:nearby_test_collector, {:stop, attrs})
      {:ok, %{discoverable: false}}
    end

    def send_nearby_request(attrs) do
      send(:nearby_test_collector, {:send_request, attrs})
      {:ok, %{request_id: "55555555-5555-4555-8555-555555555555", status: "pending"}}
    end

    def list_nearby_requests(_attrs) do
      {:ok,
       %{
         incoming: [
           %{
             request_id: "55555555-5555-4555-8555-555555555555",
             user_id: "22222222-2222-2222-2222-222222222222",
             created_at: "2026-08-25T00:00:00Z"
           }
         ],
         outgoing: [],
         connections: []
       }}
    end

    def respond_nearby_request(attrs) do
      send(:nearby_test_collector, {:respond, attrs})

      {:ok,
       %{
         request_id: "55555555-5555-4555-8555-555555555555",
         user_id: "22222222-2222-2222-2222-222222222222",
         status: if(attrs["decision"] == "accept", do: "accepted", else: "declined")
       }}
    end

    def get_public_profile(%{"user_id" => user_id}) do
      {:ok, %{user_id: user_id, display_name: "Nearby Person", avatar_media_id: nil, bio: nil}}
    end

    def get_privacy(_attrs), do: {:ok, %{profile_photo_visibility: "everyone"}}

    def get_nearby_settings(_attrs) do
      {:ok,
       Application.get_env(:api_gateway, :test_nearby_settings, %{
         enabled: true,
         ble_assist: true,
         auto_publish: false,
         audience: "everyone"
       })}
    end

    def update_nearby_settings(attrs) do
      send(:nearby_test_collector, {:update_settings, attrs})

      {:ok,
       %{
         enabled: attrs["enabled"] != false,
         ble_assist: attrs["ble_assist"] == true,
         auto_publish: attrs["auto_publish"] == true,
         audience: attrs["audience"] || "everyone"
       }}
    end

    def admit_ble_targets(attrs) do
      send(:nearby_test_collector, {:admit, attrs})

      case Application.get_env(:api_gateway, :test_ble_admitted, :echo) do
        :echo -> {:ok, %{admitted: attrs["targets"]}}
        other -> other
      end
    end
  end

  defmodule ConversationOk do
    def either_blocked?(_attrs), do: {:ok, %{blocked: false}}

    # Accept's create-or-get (audit fix 1): the SAME find-or-create path every DM uses. Captured so
    # the test can assert the pair + tenant it was called with.
    def create_conversation(attrs) do
      send(:nearby_test_collector, {:conversation, attrs})
      {:ok, %{conversation_id: "conv-nearby-1", type: "direct", created: false}}
    end
  end

  defmodule ConversationBlocked do
    def either_blocked?(_attrs), do: {:ok, %{blocked: true}}
  end

  defmodule LimiterOk do
    def check_rate(_attrs), do: :ok
  end

  defmodule LimiterTrips do
    def check_rate(_attrs), do: {:error, :rate_limited, 17}
  end

  # In-memory NearbyBleStore (the LinkStore stub precedent) — an Agent so rotation (put_get) and
  # marker reads behave exactly like Redis, deterministically.
  defmodule BleStub do
    @behaviour ApiGatewayWeb.NearbyBleStore

    def start_link, do: Agent.start_link(fn -> %{} end, name: __MODULE__)
    def dump, do: Agent.get(__MODULE__, & &1)
    def seed(key, value), do: Agent.update(__MODULE__, &Map.put(&1, key, value))

    @impl true
    def put(key, value, _ttl) do
      Agent.update(__MODULE__, &Map.put(&1, key, value))
      :ok
    end

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
        previous =
          case Map.get(state, key) do
            nil -> :was_absent
            old -> {:was_present, old}
          end

        {{:ok, previous}, Map.put(state, key, value)}
      end)
    end

    @impl true
    def del(key) do
      Agent.update(__MODULE__, &Map.delete(&1, key))
      :ok
    end
  end

  setup do
    Process.register(self(), :nearby_test_collector)

    keys = [
      auth_client_adapter: AuthStub,
      user_client_adapter: UserStub,
      conversation_client_adapter: ConversationOk,
      rate_limiter_adapter: LimiterOk
    ]

    previous = for {key, _} <- keys, into: %{}, do: {key, Application.get_env(:shared_infra, key)}
    for {key, value} <- keys, do: Application.put_env(:shared_infra, key, value)

    {:ok, _} = BleStub.start_link()
    Application.put_env(:api_gateway, :nearby_ble_store_adapter, BleStub)

    on_exit(fn ->
      for {key, value} <- previous do
        if value,
          do: Application.put_env(:shared_infra, key, value),
          else: Application.delete_env(:shared_infra, key)
      end

      Application.delete_env(:api_gateway, :nearby_ble_store_adapter)

      for key <- [:test_nearby_settings, :test_ble_admitted, :test_nearby_people],
          do: Application.delete_env(:api_gateway, key)
    end)
  end

  defp authed(method, path, params \\ %{}) do
    method
    |> conn(path, params)
    |> put_req_header("authorization", "Bearer token")
  end

  test "discover binds identity/app to the session and returns no coordinates" do
    params = %{
      "latitude" => 28.6139,
      "longitude" => 77.2090,
      "accuracy_m" => 12,
      "radius_m" => 100,
      "user_id" => "attacker-controlled"
    }

    conn = authed(:post, "/api/v1/nearby/discover", params) |> NearbyController.discover(params)
    assert conn.status == 200
    assert_receive {:discover, attrs}
    assert attrs["user_id"] == @me
    assert attrs["app_id"] == @app

    %{"people" => [person]} = Jason.decode!(conn.resp_body)
    assert person["user_id"] == @peer
    assert person["distance_bucket_m"] == 100
    refute Map.has_key?(person, "latitude")
    refute Map.has_key?(person, "longitude")
  end

  test "blocked users are hidden and cannot receive a request" do
    Application.put_env(:shared_infra, :conversation_client_adapter, ConversationBlocked)

    params = %{
      "latitude" => 28.6139,
      "longitude" => 77.2090,
      "accuracy_m" => 12,
      "radius_m" => 200
    }

    conn = authed(:post, "/api/v1/nearby/discover", params) |> NearbyController.discover(params)
    assert %{"people" => []} = Jason.decode!(conn.resp_body)

    send_params = %{"user_id" => @peer}

    conn =
      authed(:post, "/api/v1/nearby/requests", send_params)
      |> NearbyController.send_request(send_params)

    assert conn.status == 404
    refute_receive {:send_request, _}, 50
  end

  test "accept checks block state before mutating the request" do
    Application.put_env(:shared_infra, :conversation_client_adapter, ConversationBlocked)
    params = %{"request_id" => @request, "decision" => "accept"}

    conn =
      authed(:post, "/api/v1/nearby/requests/#{@request}/respond", params)
      |> NearbyController.respond(params)

    assert conn.status == 404
    refute_receive {:respond, _}, 50

    Application.put_env(:shared_infra, :conversation_client_adapter, ConversationOk)
    conn = authed(:post, "/respond", params) |> NearbyController.respond(params)
    assert conn.status == 200

    assert_receive {:respond,
                    %{"user_id" => @me, "request_id" => @request, "decision" => "accept"}}

    # ACCEPT OPENS THE CHAT (audit fix 1): the response carries the pair's conversation_id, minted
    # through the one existing direct find-or-create path (idempotency is that path's own tested
    # contract — `created: false` here IS the already-existed case passing through).
    assert %{"status" => "accepted", "conversation_id" => "conv-nearby-1"} =
             Jason.decode!(conn.resp_body)

    assert_receive {:conversation, conversation_attrs}
    assert conversation_attrs["type"] == "direct"
    assert conversation_attrs["created_by"] == @me
    assert conversation_attrs["participant_user_ids"] == [@peer]
  end

  test "REALTIME: target hears request_received; requester hears request_accepted; decline silent" do
    # Both roles land on @peer's user topic here: the TARGET of the send is @peer, and the stub's
    # respond result names @peer as the original REQUESTER of the accepted request.
    ApiGatewayWeb.Endpoint.subscribe("user:" <> @peer)

    send_params = %{"user_id" => @peer}

    conn =
      authed(:post, "/api/v1/nearby/requests", send_params)
      |> NearbyController.send_request(send_params)

    assert conn.status == 201

    assert_receive %Phoenix.Socket.Broadcast{
      event: "nearby_request_received",
      payload: %{
        "type" => "nearby_request_received",
        "request_id" => @request,
        "from_user_id" => @me
      }
    }

    accept = %{"request_id" => @request, "decision" => "accept"}
    conn = authed(:post, "/respond", accept) |> NearbyController.respond(accept)
    assert conn.status == 200

    assert_receive %Phoenix.Socket.Broadcast{
      event: "nearby_request_accepted",
      payload: %{
        "type" => "nearby_request_accepted",
        "request_id" => @request,
        "user_id" => @me,
        "conversation_id" => "conv-nearby-1"
      }
    }

    # A DECLINE emits nothing — silent by design; the requester simply never hears back.
    decline = %{"request_id" => @request, "decision" => "decline"}
    conn = authed(:post, "/respond", decline) |> NearbyController.respond(decline)
    assert conn.status == 200
    refute_receive %Phoenix.Socket.Broadcast{event: "nearby_request_accepted"}, 50
    refute_receive %Phoenix.Socket.Broadcast{event: "nearby_request_received"}, 10
  end

  test "SETTINGS: GET reflects the store; PATCH rides identity+tenant and broadcasts settings_changed" do
    conn = authed(:get, "/api/v1/nearby/settings") |> NearbyController.settings(%{})
    assert conn.status == 200

    assert %{"enabled" => true, "ble_assist" => true, "audience" => "everyone"} =
             Jason.decode!(conn.resp_body)

    ApiGatewayWeb.Endpoint.subscribe("user:" <> @me)
    params = %{"ble_assist" => true, "audience" => "contacts"}

    conn =
      authed(:patch, "/api/v1/nearby/settings", params)
      |> NearbyController.update_settings(params)

    assert conn.status == 200
    assert_receive {:update_settings, attrs}
    assert attrs["user_id"] == @me
    assert attrs["app_id"] == @app
    assert attrs["ble_assist"] == true

    assert_receive %Phoenix.Socket.Broadcast{
      event: "nearby_settings_changed",
      payload: %{"type" => "nearby_settings_changed"}
    }
  end

  test "SETTINGS RESPONSE SHAPE: every stored field is SERIALISED — asserted as an exact key set" do
    # THIS IS THE TEST THAT WAS MISSING. auto_publish (114) was wired through the store, the PATCH
    # input and the web UI, but not settings_view/1 — so it persisted correctly and was dropped on
    # the way out, and every client read null for a setting it had just written.
    #
    # Asserted as an EXACT KEY SET rather than a partial map match. The pre-existing assertion here
    # used `assert %{"enabled" => ...} = decoded`, which by construction cannot fail on a MISSING
    # key — it is why the omission survived a green suite. A field added to the store and forgotten
    # in the view now fails here.
    Application.put_env(:api_gateway, :test_nearby_settings, %{
      enabled: true,
      ble_assist: false,
      auto_publish: true,
      audience: "contacts"
    })

    conn = authed(:get, "/api/v1/nearby/settings") |> NearbyController.settings(%{})
    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert Map.keys(body) |> Enum.sort() == ["audience", "auto_publish", "ble_assist", "enabled"]
    assert body["auto_publish"] == true
  end

  test "SETTINGS: auto_publish defaults to FALSE when the store has no row" do
    # The opt-in must never read as on by omission — an absent settings row means "I never turned
    # background publishing on", and a client that saw null could render the toggle either way.
    Application.put_env(:api_gateway, :test_nearby_settings, %{
      enabled: true,
      ble_assist: false,
      audience: "everyone"
    })

    conn = authed(:get, "/api/v1/nearby/settings") |> NearbyController.settings(%{})
    body = Jason.decode!(conn.resp_body)

    assert body["auto_publish"] == false
    refute is_nil(body["auto_publish"]), "absent must serialise as false, never null"
  end

  test "SETTINGS: PATCH echoes auto_publish back, so a client can confirm what it just wrote" do
    # GET and PATCH share settings_view/1, so this pins that the write path's 200 is also readable.
    # The reported symptom was 'PATCH returns 200 but the value never appears' — the 200 body was
    # blind too, and a client trusting its own echo would have shown the toggle off after setting it.
    params = %{"auto_publish" => true}

    conn =
      authed(:patch, "/api/v1/nearby/settings", params)
      |> NearbyController.update_settings(params)

    body = Jason.decode!(conn.resp_body)

    assert conn.status == 200
    assert body["auto_publish"] == true
    assert_receive {:update_settings, attrs}
    assert attrs["auto_publish"] == true
  end

  test "BLE TOKEN: issue + ROTATION (old token resolution deleted); disabled -> 403; limited -> 429" do
    conn = authed(:post, "/api/v1/nearby/ble/token") |> NearbyController.ble_token(%{})
    assert conn.status == 200
    %{"token" => token1, "expires_in" => 300} = Jason.decode!(conn.resp_body)
    # 16 random bytes, base64url, no padding.
    assert {:ok, raw} = Base.url_decode64(token1, padding: false)
    assert byte_size(raw) == 16
    assert BleStub.dump()["nearby:ble:tok:" <> token1] == @me <> "|" <> @app

    # Re-request ROTATES: the new token resolves, the OLD one no longer does.
    conn = authed(:post, "/api/v1/nearby/ble/token") |> NearbyController.ble_token(%{})
    %{"token" => token2} = Jason.decode!(conn.resp_body)
    refute token2 == token1
    store = BleStub.dump()
    assert store["nearby:ble:tok:" <> token2] == @me <> "|" <> @app
    refute Map.has_key?(store, "nearby:ble:tok:" <> token1)
    assert store["nearby:ble:cur:" <> @me] == token2

    # Master off / ble off -> 403 nearby.disabled (both gates behind one code).
    Application.put_env(:api_gateway, :test_nearby_settings, %{
      enabled: true,
      ble_assist: false,
      audience: "everyone"
    })

    conn = authed(:post, "/api/v1/nearby/ble/token") |> NearbyController.ble_token(%{})
    assert conn.status == 403
    assert %{"error" => %{"code" => "nearby.disabled"}} = Jason.decode!(conn.resp_body)

    # Rate limited (fail-closed surface) -> 429 with retry-after.
    Application.put_env(:shared_infra, :rate_limiter_adapter, LimiterTrips)
    conn = authed(:post, "/api/v1/nearby/ble/token") |> NearbyController.ble_token(%{})
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") == ["17"]
  end

  test "BLE SIGHTINGS: resolution drops (unknown/cross-app/self) before the store; COUNT-ONLY response; markers written" do
    peer2 = "66666666-6666-4666-8666-666666666666"
    BleStub.seed("nearby:ble:tok:tok-peer", @peer <> "|" <> @app)
    BleStub.seed("nearby:ble:tok:tok-peer2", peer2 <> "|" <> @app)
    BleStub.seed("nearby:ble:tok:tok-foreign", "77777777-7777-4777-8777-777777777777|other-app")
    BleStub.seed("nearby:ble:tok:tok-self", @me <> "|" <> @app)

    params = %{"tokens" => ["tok-peer", "tok-peer2", "tok-foreign", "tok-self", "tok-unknown"]}

    conn =
      authed(:post, "/api/v1/nearby/ble/sightings", params)
      |> NearbyController.ble_sightings(params)

    assert conn.status == 200

    # THE RESPONSE IS A COUNT AND NOTHING ELSE — which tokens resolved is never disclosed.
    assert Jason.decode!(conn.resp_body) == %{"matched" => 2}

    # Only same-app non-self candidates reached the store-level admission.
    assert_receive {:admit, attrs}
    assert attrs["user_id"] == @me
    assert attrs["app_id"] == @app
    assert Enum.sort(attrs["targets"]) == Enum.sort([@peer, peer2])

    # A 120s proximity marker per admitted pair.
    store = BleStub.dump()
    assert store["nearby:ble:prox:" <> @me <> ":" <> @peer] == "1"
    assert store["nearby:ble:prox:" <> @me <> ":" <> peer2] == "1"

    # No live presence (store says so) -> 409 presence_required, nothing written.
    Application.put_env(:api_gateway, :test_ble_admitted, {:error, :nearby_presence_required})

    conn =
      authed(:post, "/api/v1/nearby/ble/sightings", params)
      |> NearbyController.ble_sightings(params)

    assert conn.status == 409
    assert %{"error" => %{"code" => "nearby.presence_required"}} = Jason.decode!(conn.resp_body)

    # >20 tokens or a non-list is invalid at the boundary.
    bad = %{"tokens" => Enum.map(1..21, &"t#{&1}")}

    conn =
      authed(:post, "/api/v1/nearby/ble/sightings", bad) |> NearbyController.ble_sightings(bad)

    assert conn.status == 400
  end

  test "DISCOVER OVERLAY: a live marker shows bucket \"ble\" ordered first; expiry reverts to the PINNED GPS bucket" do
    # The store returns the target with its PINNED GPS bucket (200). A live proximity marker
    # overlays "ble"; when the marker dies the response falls back to 200 — never a refined 100:
    # no BLE path touches the pin, so a sighting cannot narrow the GPS bucket.
    peer2 = "66666666-6666-4666-8666-666666666666"

    Application.put_env(:api_gateway, :test_nearby_people, [
      %{user_id: @peer, distance_bucket_m: 100, relationship: "none"},
      %{user_id: peer2, distance_bucket_m: 200, relationship: "none"}
    ])

    BleStub.seed("nearby:ble:prox:" <> @me <> ":" <> peer2, "1")

    params = %{
      "latitude" => 28.6139,
      "longitude" => 77.2090,
      "accuracy_m" => 12,
      "radius_m" => 200
    }

    conn = authed(:post, "/api/v1/nearby/discover", params) |> NearbyController.discover(params)
    assert conn.status == 200
    %{"people" => people} = Jason.decode!(conn.resp_body)

    assert Enum.map(people, &{&1["user_id"], &1["distance_bucket_m"]}) == [
             {peer2, "ble"},
             {@peer, 100}
           ]

    # Marker gone (TTL expiry) -> the pinned GPS bucket 200 returns, unrefined.
    BleStub.del("nearby:ble:prox:" <> @me <> ":" <> peer2)
    conn = authed(:post, "/api/v1/nearby/discover", params) |> NearbyController.discover(params)
    %{"people" => reverted} = Jason.decode!(conn.resp_body)

    assert Enum.map(reverted, &{&1["user_id"], &1["distance_bucket_m"]}) == [
             {@peer, 100},
             {peer2, 200}
           ]
  end

  test "stop is session-owned" do
    conn = authed(:delete, "/api/v1/nearby/presence") |> NearbyController.stop(%{})
    assert conn.status == 200
    assert_receive {:stop, %{"user_id" => @me}}
  end
end

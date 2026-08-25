defmodule UserService.NearbyTest do
  use UserService.DataCase, async: false

  alias UserService.Nearby

  @app_id "00000000-0000-0000-0000-000000000001"
  @delhi_lat 28.6139
  @delhi_lng 77.2090

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, email, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @app_id, "#{id}@nearby.test"]
    )

    id
  end

  defp discover(user_id, lat, radius \\ 200) do
    Nearby.discover(%{
      "user_id" => user_id,
      "app_id" => @app_id,
      "latitude" => lat,
      "longitude" => @delhi_lng,
      "accuracy_m" => 12,
      "radius_m" => radius
    })
  end

  @tag :postgres_integration
  test "discovery is opt-in, radius-bound, coarse, and stop revokes it" do
    me = user!()
    near_50m = user!()
    near_150m = user!()
    outside = user!()

    assert {:ok, _} = discover(near_50m, @delhi_lat + 0.0004)
    assert {:ok, _} = discover(near_150m, @delhi_lat + 0.00135)
    assert {:ok, _} = discover(outside, @delhi_lat + 0.003)

    assert {:ok, %{people: within_100}} = discover(me, @delhi_lat, 100)
    assert Enum.map(within_100, & &1.user_id) == [near_50m]
    # 100/200 only — the 50 m bucket was dropped (trilateration hardening).
    assert hd(within_100).distance_bucket_m == 100
    refute Map.has_key?(hd(within_100), :latitude)
    refute Map.has_key?(hd(within_100), :longitude)

    assert {:ok, %{people: within_200}} = discover(me, @delhi_lat, 200)
    assert Enum.map(within_200, & &1.user_id) == [near_50m, near_150m]
    assert Enum.map(within_200, & &1.distance_bucket_m) == [100, 200]

    assert {:ok, %{discoverable: false}} = Nearby.stop(%{"user_id" => near_50m})
    assert {:ok, %{people: after_stop}} = discover(me, @delhi_lat, 200)
    refute Enum.any?(after_stop, &(&1.user_id == near_50m))
  end

  @tag :postgres_integration
  test "connection requires a live nearby presence and recipient acceptance" do
    sender = user!()
    recipient = user!()
    stale_target = user!()
    far_target = user!()

    assert {:ok, _} = discover(sender, @delhi_lat)
    assert {:ok, _} = discover(recipient, @delhi_lat + 0.0004)
    assert {:ok, _} = discover(far_target, @delhi_lat + 0.003)

    assert {:error, :nearby_not_discoverable} =
             Nearby.send_request(%{
               "requester_user_id" => sender,
               "recipient_user_id" => stale_target,
               "app_id" => @app_id
             })

    # A caller cannot use a user id learned elsewhere to bypass the 200 m boundary merely because
    # both accounts happen to have Nearby open.
    assert {:error, :nearby_not_discoverable} =
             Nearby.send_request(%{
               "requester_user_id" => sender,
               "recipient_user_id" => far_target,
               "app_id" => @app_id
             })

    assert {:ok, %{request_id: request_id, status: "pending"}} =
             Nearby.send_request(%{
               "requester_user_id" => sender,
               "recipient_user_id" => recipient,
               "app_id" => @app_id
             })

    assert {:error, :nearby_request_exists} =
             Nearby.send_request(%{
               "requester_user_id" => recipient,
               "recipient_user_id" => sender,
               "app_id" => @app_id
             })

    assert {:ok, %{outgoing: [%{request_id: ^request_id, user_id: ^recipient}]}} =
             Nearby.list_requests(%{"user_id" => sender, "app_id" => @app_id})

    assert {:ok, %{incoming: [%{request_id: ^request_id, user_id: ^sender}]}} =
             Nearby.list_requests(%{"user_id" => recipient, "app_id" => @app_id})

    assert {:ok, %{status: "accepted", user_id: ^sender}} =
             Nearby.respond(%{
               "user_id" => recipient,
               "request_id" => request_id,
               "decision" => "accept"
             })

    assert {:ok, %{connections: [%{user_id: ^recipient}]}} =
             Nearby.list_requests(%{"user_id" => sender, "app_id" => @app_id})

    assert {:error, :nearby_request_not_found} =
             Nearby.respond(%{
               "user_id" => recipient,
               "request_id" => request_id,
               "decision" => "accept"
             })
  end

  @tag :postgres_integration
  test "invalid coordinates, low accuracy, and self-requests fail" do
    me = user!()

    assert {:error, :nearby_invalid} = discover(me, 91.0)

    assert {:error, :nearby_accuracy_too_low} =
             Nearby.discover(%{
               "user_id" => me,
               "app_id" => @app_id,
               "latitude" => @delhi_lat,
               "longitude" => @delhi_lng,
               "accuracy_m" => 101,
               "radius_m" => 200
             })

    assert {:error, :nearby_invalid} =
             Nearby.send_request(%{
               "requester_user_id" => me,
               "recipient_user_id" => me,
               "app_id" => @app_id
             })
  end

  @tag :postgres_integration
  test "PINNING: a moving viewer keeps the first bucket for a target; a fresh presence re-pins" do
    me = user!()
    target = user!()

    # Target sits ~150 m north; my first discover pins them at bucket 200.
    assert {:ok, _} = discover(target, @delhi_lat + 0.00135)
    assert {:ok, %{people: [first]}} = discover(me, @delhi_lat)
    assert first.user_id == target and first.distance_bucket_m == 200

    # I move right next to them (~45 m) — computed would be 100, but the PIN holds: boundary-walking
    # reveals nothing within one presence lifetime.
    assert {:ok, %{people: [moved]}} = discover(me, @delhi_lat + 0.0009)
    assert moved.distance_bucket_m == 200

    # The target stops and starts a FRESH presence → the pin died with the old row → re-pinned from
    # my current (close) position.
    assert {:ok, _} = Nearby.stop(%{"user_id" => target})
    assert {:ok, _} = discover(target, @delhi_lat + 0.00135)
    assert {:ok, %{people: [fresh]}} = discover(me, @delhi_lat + 0.0009)
    assert fresh.distance_bucket_m == 100
  end

  @tag :postgres_integration
  test "RETENTION: an expired presence row is physically deleted by the next discover" do
    me = user!()
    ghost = user!()

    assert {:ok, _} = discover(ghost, @delhi_lat)

    Repo.query!(
      "UPDATE nearby_presence SET expires_at = now() - interval '1 minute' WHERE user_id = $1::text::uuid",
      [ghost]
    )

    assert {:ok, %{people: people}} = discover(me, @delhi_lat)
    refute Enum.any?(people, &(&1.user_id == ghost))

    # Not merely filtered — GONE (raw coordinates do not sit at rest past expiry).
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*)::int FROM nearby_presence WHERE user_id = $1::text::uuid",
        [ghost]
      )

    assert count == 0
  end

  @tag :postgres_integration
  test "DECLINE COOLDOWN: same-direction re-request refused for 24h; reverse + post-window allowed" do
    requester = user!()
    recipient = user!()
    assert {:ok, _} = discover(requester, @delhi_lat)
    assert {:ok, _} = discover(recipient, @delhi_lat + 0.0004)

    {:ok, %{request_id: request_id}} =
      Nearby.send_request(%{
        "requester_user_id" => requester,
        "recipient_user_id" => recipient,
        "app_id" => @app_id
      })

    assert {:ok, %{status: "declined"}} =
             Nearby.respond(%{
               "user_id" => recipient,
               "request_id" => request_id,
               "decision" => "decline"
             })

    # Same direction, inside the window → cooldown.
    assert {:error, :nearby_request_cooldown} =
             Nearby.send_request(%{
               "requester_user_id" => requester,
               "recipient_user_id" => recipient,
               "app_id" => @app_id
             })

    # The DECLINED side choosing to reach out the other way is allowed.
    assert {:ok, _} =
             Nearby.send_request(%{
               "requester_user_id" => recipient,
               "recipient_user_id" => requester,
               "app_id" => @app_id
             })

    # Backdate the decline past 24h → the original direction opens again (cancel the reverse pending
    # first: one pending per pair).
    Repo.query!(
      "UPDATE nearby_connection_requests SET status = 'cancelled' WHERE status = 'pending'",
      []
    )

    Repo.query!(
      "UPDATE nearby_connection_requests SET responded_at = now() - interval '25 hours' " <>
        "WHERE id = $1::text::uuid",
      [request_id]
    )

    assert {:ok, _} =
             Nearby.send_request(%{
               "requester_user_id" => requester,
               "recipient_user_id" => recipient,
               "app_id" => @app_id
             })
  end
end

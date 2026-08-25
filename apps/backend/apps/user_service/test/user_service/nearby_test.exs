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
  test "SETTINGS (104): defaults, partial PATCH (false is a value), disable deletes presence + refuses discover" do
    me = user!()

    assert {:ok, %{enabled: true, ble_assist: false, audience: "everyone"}} =
             Nearby.get_settings(%{"user_id" => me})

    # Partial update: only the provided key changes; enabled=false is a VALUE, not absent.
    assert {:ok, %{enabled: true, ble_assist: true, audience: "everyone"}} =
             Nearby.update_settings(%{"user_id" => me, "app_id" => @app_id, "ble_assist" => true})

    assert {:ok, %{enabled: true, ble_assist: true, audience: "contacts"}} =
             Nearby.update_settings(%{
               "user_id" => me,
               "app_id" => @app_id,
               "audience" => "contacts"
             })

    assert {:error, :nearby_invalid} =
             Nearby.update_settings(%{"user_id" => me, "app_id" => @app_id, "audience" => "vips"})

    # MASTER OFF: the live presence row dies in the same transaction, and discover refuses.
    assert {:ok, _} = discover(me, @delhi_lat)

    %{rows: [[before_off]]} =
      Repo.query!(
        "SELECT count(*)::int FROM nearby_presence WHERE user_id = $1::text::uuid",
        [me]
      )

    assert before_off == 1

    assert {:ok, %{enabled: false}} =
             Nearby.update_settings(%{"user_id" => me, "app_id" => @app_id, "enabled" => false})

    %{rows: [[after_off]]} =
      Repo.query!(
        "SELECT count(*)::int FROM nearby_presence WHERE user_id = $1::text::uuid",
        [me]
      )

    assert after_off == 0
    assert {:error, :nearby_disabled} = discover(me, @delhi_lat)

    # And BLE admission refuses too (master off gates everything).
    assert {:error, :nearby_disabled} =
             Nearby.admit_ble_targets(%{
               "user_id" => me,
               "app_id" => @app_id,
               "targets" => [Ecto.UUID.generate()]
             })

    # Back on: everything reopens (presence returns only when sharing again — unchanged contract).
    assert {:ok, %{enabled: true}} =
             Nearby.update_settings(%{"user_id" => me, "app_id" => @app_id, "enabled" => true})

    assert {:ok, _} = discover(me, @delhi_lat)
  end

  @tag :postgres_integration
  test "AUDIENCE, BOTH DIRECTIONS: each side's audience must admit the other" do
    viewer = user!()
    target = user!()

    assert {:ok, _} = discover(target, @delhi_lat + 0.0004)

    sees? = fn ->
      {:ok, %{people: people}} = discover(viewer, @delhi_lat, 200)
      Enum.any?(people, &(&1.user_id == target))
    end

    # Defaults: both everyone → visible.
    assert sees?.()

    # TARGET restricts to contacts; viewer is not one → invisible (target direction).
    {:ok, _} =
      Nearby.update_settings(%{
        "user_id" => target,
        "app_id" => @app_id,
        "audience" => "contacts"
      })

    refute sees?.()

    # Target favourites the viewer → visible again.
    fav!(target, viewer)
    assert sees?.()

    # VIEWER restricts to contacts; target is not the viewer's favourite → invisible (viewer
    # direction — your audience also limits who YOU see).
    {:ok, _} =
      Nearby.update_settings(%{
        "user_id" => viewer,
        "app_id" => @app_id,
        "audience" => "contacts"
      })

    refute sees?.()

    # Viewer favourites the target → both directions admit → visible.
    fav!(viewer, target)
    assert sees?.()

    # Target's settings row says enabled=false WITH a presence row still live (inserted directly —
    # the update path would delete it): the SQL itself must exclude — defense in depth.
    Repo.query!(
      "UPDATE nearby_settings SET enabled = false WHERE user_id = $1::text::uuid",
      [target]
    )

    refute sees?.()
  end

  @tag :postgres_integration
  test "BLE ADMISSION (104): presence-required plus the store-level drop matrix" do
    viewer = user!()
    ok_target = user!()
    blocked_target = user!()
    contacts_only = user!()
    disabled_target = user!()
    foreign = foreign_app_user!()

    # No live presence → presence_required (BLE assists discovery, never lurk-mode).
    assert {:error, :nearby_presence_required} =
             Nearby.admit_ble_targets(%{
               "user_id" => viewer,
               "app_id" => @app_id,
               "targets" => [ok_target]
             })

    assert {:ok, _} = discover(viewer, @delhi_lat)

    block!(blocked_target, viewer)

    {:ok, _} =
      Nearby.update_settings(%{
        "user_id" => contacts_only,
        "app_id" => @app_id,
        "audience" => "contacts"
      })

    {:ok, _} =
      Nearby.update_settings(%{
        "user_id" => disabled_target,
        "app_id" => @app_id,
        "enabled" => false
      })

    assert {:ok, %{admitted: admitted}} =
             Nearby.admit_ble_targets(%{
               "user_id" => viewer,
               "app_id" => @app_id,
               "targets" => [
                 ok_target,
                 blocked_target,
                 contacts_only,
                 disabled_target,
                 foreign,
                 viewer
               ]
             })

    # Only the unencumbered same-app target survives: blocked (either direction), audience-refusing,
    # disabled, cross-app, and self are all dropped BY THE STORE.
    assert admitted == [ok_target]

    # Audience heals when the target favourites the viewer.
    fav!(contacts_only, viewer)

    assert {:ok, %{admitted: healed}} =
             Nearby.admit_ble_targets(%{
               "user_id" => viewer,
               "app_id" => @app_id,
               "targets" => [contacts_only]
             })

    assert healed == [contacts_only]

    # >20 targets is invalid at the boundary.
    too_many = for _ <- 1..21, do: Ecto.UUID.generate()

    assert {:error, :nearby_invalid} =
             Nearby.admit_ble_targets(%{
               "user_id" => viewer,
               "app_id" => @app_id,
               "targets" => too_many
             })
  end

  defp fav!(owner, favourite) do
    Repo.query!(
      "INSERT INTO favourite_contacts (owner_user_id, favourite_user_id, app_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid) ON CONFLICT DO NOTHING",
      [owner, favourite, @app_id]
    )
  end

  defp foreign_app_user! do
    app = Ecto.UUID.generate()

    Repo.query!("INSERT INTO apps (id, name, slug) VALUES ($1::text::uuid, 'F', $2)", [
      app,
      "f-#{app}"
    ])

    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, app, "+1#{System.unique_integer([:positive])}"]
    )

    id
  end

  @tag :postgres_integration
  test "STORE-LEVEL block exclusion: a blocked pair never surfaces or qualifies, gateway bypassed" do
    me = user!()
    # Either direction blocks: one account blocked me, the other I blocked.
    blocker = user!()
    blocked = user!()
    visible = user!()

    for {peer, offset} <- [{blocker, 0.0004}, {blocked, 0.0005}, {visible, 0.0006}] do
      assert {:ok, _} = discover(peer, @delhi_lat + offset)
    end

    block!(blocker, me)
    block!(me, blocked)

    # The store function called DIRECTLY — no gateway either_blocked? wall anywhere in this suite:
    # the SQL itself must exclude both directions (defense-in-depth behind the outer wall).
    assert {:ok, %{people: people}} = discover(me, @delhi_lat, 200)
    assert Enum.map(people, & &1.user_id) == [visible]

    # Request eligibility, same store level: a blocked pair fails EXACTLY like any other
    # non-discoverable target — no distinct error that would leak the block's existence.
    assert {:error, :nearby_not_discoverable} = send_request(me, blocked)
    assert {:error, :nearby_not_discoverable} = send_request(me, blocker)

    # The unblocked pair still qualifies (the exclusion is a filter, not a lockout).
    assert {:ok, %{status: "pending"}} = send_request(me, visible)
  end

  defp block!(blocker_id, blocked_id) do
    Repo.query!(
      "INSERT INTO user_blocks (blocker_user_id, blocked_user_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid)",
      [blocker_id, blocked_id]
    )
  end

  defp send_request(requester, recipient) do
    Nearby.send_request(%{
      "requester_user_id" => requester,
      "recipient_user_id" => recipient,
      "app_id" => @app_id
    })
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

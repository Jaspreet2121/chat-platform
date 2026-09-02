defmodule UserService.Nearby do
  @moduledoc """
  Privacy-first Nearby People domain. Discovery is explicit and short-lived; coordinates stay inside
  this service and only coarse 100/200 metre buckets leave it — PINNED per (viewer, target) pair
  for the target row's lifetime, so repeated queries from a moving viewer cannot walk the bucket
  boundary (trilateration hardening). Expired rows are physically deleted, not just filtered. Connections require the recipient
  to accept a pending request.
  """

  alias UserService.Repo

  # RETENTION, one constant for every write path (the discover self-upsert AND the publish endpoint).
  # Was 300s: presence existed only while Nearby was open. Now 8h, because phones publish in the
  # background for opted-in users. The physical delete-on-expiry sweep is unchanged — a coordinate
  # past this edge is REMOVED, never merely filtered out of a query.
  @presence_seconds 28_800

  # BOUND AS A STRING, cast in SQL — the file's `$N::text::<type>` convention, and here it is load
  # bearing rather than stylistic. `($6 || ' seconds')` makes Postgrex infer $6 as TEXT from the
  # concatenation operator; binding the integer raises DBConnection.EncodeError at runtime and takes
  # discover down with it. Compiling proves nothing about a parameter's wire type.
  defp presence_seconds_param, do: Integer.to_string(@presence_seconds)

  # Staleness, as CEILING buckets in seconds. Coarse on purpose: a viewer learns "roughly how old"
  # without ever receiving a timestamp they could difference against a second observation to infer
  # movement. "now" absorbs everything under ten minutes, so an actively-publishing phone never leaks
  # its publish cadence.
  @staleness_buckets [{600, "now"}, {3_600, "1h"}, {7_200, "2h"}, {14_400, "4h"}]
  @staleness_max "8h"

  # A publish must move the stored fix by at least this much to count as a NEW fix (fix_seq++), which
  # is what retires per-viewer bucket pins. Below it, a phone re-reporting the same place — GPS jitter,
  # a stationary device — keeps the existing pins and cannot be used to probe the bucket boundary.
  @fix_move_threshold_m 25.0
  @max_results 30
  @valid_radii [100, 200]
  @audiences ~w(everyone contacts)

  @doc """
  Per-user discoverability settings (104). Absent row = the defaults — enabled (the master switch;
  presence still only exists while actively sharing), no BLE assist, audience everyone.
  """
  def get_settings(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id") do
      {:ok, settings_row(user_id)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
  end

  @doc """
  PATCH semantics: only provided keys change (booleans matched EXPLICITLY — the falsy-mget trap:
  `false` must never read as absent). Setting `enabled` false DELETES any live presence row in the
  same transaction — flipping the master switch off must revoke discoverability immediately, not at
  the five-minute expiry.
  """
  def update_settings(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, enabled} <- optional_bool(attrs, "enabled", :enabled),
         {:ok, ble_assist} <- optional_bool(attrs, "ble_assist", :ble_assist),
         {:ok, auto_publish} <- optional_bool(attrs, "auto_publish", :auto_publish),
         {:ok, audience} <- optional_audience(attrs) do
      {:ok, settings} =
        Repo.transaction(fn ->
          Repo.query!(
            """
            INSERT INTO nearby_settings
              (user_id, app_id, enabled, ble_assist, audience, auto_publish, updated_at)
            VALUES ($1::text::uuid, $2::text::uuid,
                    COALESCE($3, true), COALESCE($4, false), COALESCE($5, 'everyone'),
                    COALESCE($6, false), now())
            ON CONFLICT (user_id) DO UPDATE SET
              app_id = EXCLUDED.app_id,
              enabled = COALESCE($3, nearby_settings.enabled),
              ble_assist = COALESCE($4, nearby_settings.ble_assist),
              audience = COALESCE($5, nearby_settings.audience),
              -- auto_publish rides the same COALESCE-partial-PATCH rule as the others; false is a
              -- VALUE here, which is why it comes through optional_bool and never the falsy-mget
              -- helper.
              auto_publish = COALESCE($6, nearby_settings.auto_publish),
              updated_at = now()
            """,
            [user_id, app_id, enabled, ble_assist, audience, auto_publish]
          )

          if enabled == false do
            Repo.query!(
              "DELETE FROM nearby_presence WHERE user_id = $1::text::uuid",
              [user_id]
            )
          end

          settings_row(user_id)
        end)

      {:ok, settings}
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
    _error in Postgrex.Error -> {:error, :nearby_invalid}
  end

  def discover(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, latitude} <- coordinate(attrs, "latitude", -90.0, 90.0),
         {:ok, longitude} <- coordinate(attrs, "longitude", -180.0, 180.0),
         {:ok, accuracy} <- accuracy(attrs),
         {:ok, radius} <- radius(attrs),
         {:ok, viewer} <- require_enabled(user_id) do
      # RETENTION: expired rows are DELETED, not merely filtered — stale coordinates must not sit at
      # rest, and a re-created row starting fresh is what resets the per-viewer bucket pins.
      Repo.query!(
        "DELETE FROM nearby_presence WHERE app_id = $1::text::uuid AND expires_at < now()",
        [app_id]
      )

      Repo.query!(
        """
        INSERT INTO nearby_presence
          (user_id, app_id, latitude, longitude, accuracy_m, expires_at, updated_at)
        VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5,
                now() + ($6::text || ' seconds')::interval, now())
        ON CONFLICT (user_id) DO UPDATE SET
          app_id = EXCLUDED.app_id,
          latitude = EXCLUDED.latitude,
          longitude = EXCLUDED.longitude,
          accuracy_m = EXCLUDED.accuracy_m,
          expires_at = EXCLUDED.expires_at,
          updated_at = EXCLUDED.updated_at,
          -- A REFRESH of a live row keeps its viewers' pins; only an expired remnant resets them.
          pins = CASE WHEN nearby_presence.expires_at > now()
                      THEN nearby_presence.pins ELSE '{}'::jsonb END
        """,
        [user_id, app_id, latitude, longitude, accuracy, presence_seconds_param()]
      )

      {box_min_lat, box_max_lat, box_min_lng, box_max_lng} =
        bounding_box(latitude, longitude, radius * 1.0)

      %{rows: rows} =
        Repo.query!(
          """
          WITH candidates AS (
            SELECT p.user_id, p.pins ->> ($1 || ':' || p.fix_seq::text) AS pinned_bucket, p.fix_seq,
              EXTRACT(EPOCH FROM (now() - p.updated_at))::float AS age_seconds,
              6371000.0 * 2.0 * asin(LEAST(1.0, sqrt(
                power(sin(radians((p.latitude - $3) / 2.0)), 2) +
                cos(radians($3)) * cos(radians(p.latitude)) *
                power(sin(radians((p.longitude - $4) / 2.0)), 2)
              ))) AS distance_m
            FROM nearby_presence p
            JOIN users_auth a ON a.id = p.user_id AND a.status = 'active'
            WHERE p.app_id = $2::text::uuid
              -- BOUNDING-BOX PREFILTER (114). A haversine cannot use an index, so before the 8h TTL
              -- this scanned every live row in the app and computed a great-circle distance for each.
              -- The box is a strict SUPERSET of the circle and rides the (app_id, latitude) INCLUDE
              -- (longitude) index; the haversine below still decides membership, so the box can only
              -- ever remove rows that were going to fail it anyway.
              AND p.latitude BETWEEN $7 AND $8
              AND p.longitude BETWEEN $9 AND $10
              AND p.user_id <> $1::text::uuid
              AND p.expires_at > now()
              -- STORE-LEVEL block exclusion (defense-in-depth): a blocked pair — either direction —
              -- never surfaces from this query, even if the gateway's outer wall were bypassed.
              AND NOT EXISTS (
                SELECT 1 FROM user_blocks ub
                WHERE (ub.blocker_user_id = $1::text::uuid AND ub.blocked_user_id = p.user_id)
                   OR (ub.blocker_user_id = p.user_id AND ub.blocked_user_id = $1::text::uuid)
              )
              -- AUDIENCE, BOTH DIRECTIONS (104): the target's settings must admit the viewer AND
              -- the viewer's audience ($6) must admit the target. Absent row = enabled/everyone.
              AND COALESCE((SELECT s.enabled FROM nearby_settings s WHERE s.user_id = p.user_id), true)
              AND (COALESCE((SELECT s.audience FROM nearby_settings s WHERE s.user_id = p.user_id),
                            'everyone') = 'everyone'
                   OR EXISTS (SELECT 1 FROM favourite_contacts tf
                              WHERE tf.owner_user_id = p.user_id
                                AND tf.favourite_user_id = $1::text::uuid))
              AND ($6 = 'everyone'
                   OR EXISTS (SELECT 1 FROM favourite_contacts vf
                              WHERE vf.owner_user_id = $1::text::uuid
                                AND vf.favourite_user_id = p.user_id))
          )
          SELECT c.user_id::text, c.distance_m, c.pinned_bucket, c.fix_seq, c.age_seconds,
            CASE
              WHEN nc.user_low_id IS NOT NULL THEN 'connected'
              WHEN sent.id IS NOT NULL THEN 'sent'
              WHEN received.id IS NOT NULL THEN 'received'
              ELSE 'none'
            END AS relationship
          FROM candidates c
          LEFT JOIN nearby_connections nc
            ON nc.app_id = $2::text::uuid
           AND nc.user_low_id = LEAST($1::text::uuid, c.user_id)
           AND nc.user_high_id = GREATEST($1::text::uuid, c.user_id)
          LEFT JOIN nearby_connection_requests sent
            ON sent.requester_user_id = $1::text::uuid AND sent.recipient_user_id = c.user_id
           AND sent.status = 'pending'
          LEFT JOIN nearby_connection_requests received
            ON received.requester_user_id = c.user_id AND received.recipient_user_id = $1::text::uuid
           AND received.status = 'pending'
          WHERE c.distance_m <= $5::double precision
          -- Freshest first, then nearest. (BLE-confirmed rows are hoisted above all of these by the
          -- gateway's overlay, which is the only layer that knows about Bluetooth sightings.)
          ORDER BY c.age_seconds, c.distance_m, c.user_id
          LIMIT #{@max_results}
          """,
          [
            user_id,
            app_id,
            latitude,
            longitude,
            radius * 1.0,
            viewer.audience,
            box_min_lat,
            box_max_lat,
            box_min_lng,
            box_max_lng
          ]
        )

      people =
        Enum.map(rows, fn [id, distance, pinned, fix_seq, age_seconds, relationship] ->
          # THE PIN KEY IS (viewer, target-fix). Scoping it to the target's fix_seq is what keeps the
          # anti-trilateration property alive under an 8h TTL:
          #
          #   * a VIEWER who moves and re-queries reads the same key, so a stationary target's bucket
          #     never changes — an attacker still cannot walk the 100/200 m boundary to triangulate;
          #   * a TARGET who genuinely moves advances fix_seq, the old key stops matching, and the
          #     bucket is recomputed once for the new position.
          #
          # Under the old rule (frozen for the row's LIFETIME) an 8h row would have shown a bucket
          # from eight hours ago forever, which is both wrong and its own privacy problem — it would
          # advertise where someone WAS long after they left.
          pin_key = pin_key(user_id, fix_seq)
          bucket = pinned_or_computed(pinned, distance)

          if is_nil(pinned) do
            Repo.query!(
              "UPDATE nearby_presence SET pins = pins || jsonb_build_object($1::text, $2::int) " <>
                "WHERE user_id = $3::text::uuid AND expires_at > now()",
              [pin_key, bucket, id]
            )
          end

          %{
            user_id: id,
            distance_bucket_m: bucket,
            last_seen_bucket: staleness_bucket(age_seconds),
            relationship: relationship
          }
        end)

      {:ok, %{people: people, expires_in_seconds: @presence_seconds, radius_m: radius}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
    _error in Postgrex.Error -> {:error, :nearby_invalid}
  end

  @doc """
  The bounding box for a radius around a point, as {min_lat, max_lat, min_lng, max_lng}.

  A STRICT SUPERSET of the circle — that is the only correctness requirement, and it is why the
  Haversine still runs afterwards. The box exists to stop the scan touching every live row in the
  app; it must never be the thing that decides membership, or a point just inside the radius would
  be silently dropped.

  Longitude degrees shrink as cos(latitude), so the longitude half-width is divided by that cosine.
  Two guards keep it a superset where that division misbehaves:

    * near the poles cos(lat) approaches 0 and the half-width explodes — clamped to the full
      -180..180 range, which is a superset by definition and correct: near a pole a small radius
      really does span every meridian;
    * the box is padded by 1% plus a metre before conversion, so floating-point error in the
      cosine or in the degree conversion cannot pull an edge INSIDE the circle.

  Latitude is clamped to [-90, 90]; the longitude range is NOT wrapped across the antimeridian —
  it widens to the full range instead, again preferring a superset over a clever split.
  """
  @earth_radius_m 6_371_000.0
  @box_padding 1.01
  @box_padding_m 1.0

  def bounding_box(latitude, longitude, radius_m) do
    padded = radius_m * @box_padding + @box_padding_m
    lat_delta = padded / @earth_radius_m * 180.0 / :math.pi()

    min_lat = max(latitude - lat_delta, -90.0)
    max_lat = min(latitude + lat_delta, 90.0)

    # Evaluate the cosine at the WIDEST latitude the box reaches, not at the centre: that is where
    # longitude degrees are shortest, so it yields the widest (safest) longitude delta.
    widest = max(abs(min_lat), abs(max_lat))
    cos_lat = :math.cos(widest * :math.pi() / 180.0)

    if cos_lat <= 0.01 do
      {min_lat, max_lat, -180.0, 180.0}
    else
      lng_delta = lat_delta / cos_lat

      if lng_delta >= 180.0 do
        {min_lat, max_lat, -180.0, 180.0}
      else
        {min_lat, max_lat, longitude - lng_delta, longitude + lng_delta}
      end
    end
  end

  @doc """
  Coarse staleness from an age in seconds. CEILING buckets, never a timestamp: a viewer learns
  "roughly how old" and cannot difference two observations to infer that someone moved.

  Public + pure so it can be tested directly and so the boundaries are pinned by name rather than by
  reading the SQL.
  """
  def staleness_bucket(age_seconds) when is_number(age_seconds) do
    age = max(age_seconds, 0)

    Enum.find_value(@staleness_buckets, @staleness_max, fn {ceiling, label} ->
      if age <= ceiling, do: label
    end)
  end

  def staleness_bucket(_), do: @staleness_max

  @doc """
  The per-viewer pin key. Scoped to the TARGET's fix generation, which is the whole
  anti-trilateration property: a moving viewer reads the same key (bucket frozen), a moving target
  advances fix_seq and retires the key (bucket recomputed once).
  """
  def pin_key(viewer_id, fix_seq), do: "#{viewer_id}:#{fix_seq}"

  @doc "Did an accepted publish move the stored fix far enough to count as a new one?"
  def new_fix?(nil, _lat, _lng), do: true

  def new_fix?({prev_lat, prev_lng}, lat, lng) do
    haversine_m(prev_lat, prev_lng, lat, lng) >= @fix_move_threshold_m
  end

  @doc """
  PUBLISH-ONLY upsert — the background path (114). Writes a fix without running discovery, so a
  phone can keep its owner visible while Nearby is closed.

  THE SERVER IS THE WALL. Publishing requires BOTH the master switch (`enabled`) and the explicit
  `auto_publish` opt-in. The client worker checks too, but a client check is a courtesy: a stale
  build, a replayed request, or a modified app must not be able to publish for a user who never
  opted in. `enabled=false` refuses as :nearby_disabled (as everywhere else); opted-out refuses with
  its own :nearby_publish_disabled so the client can tell "you turned Nearby off" from "you never
  turned background publishing on".
  """
  def publish(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, latitude} <- coordinate(attrs, "latitude", -90.0, 90.0),
         {:ok, longitude} <- coordinate(attrs, "longitude", -180.0, 180.0),
         {:ok, accuracy} <- accuracy(attrs),
         {:ok, _settings} <- require_publish_allowed(user_id) do
      Repo.query!(
        "DELETE FROM nearby_presence WHERE app_id = $1::text::uuid AND expires_at < now()",
        [app_id]
      )

      previous = previous_fix(user_id)
      advance? = new_fix?(previous, latitude, longitude)

      Repo.query!(
        """
        INSERT INTO nearby_presence
          (user_id, app_id, latitude, longitude, accuracy_m, expires_at, updated_at, fix_seq, pins)
        VALUES ($1::text::uuid, $2::text::uuid, $3, $4, $5,
                now() + ($6::text || ' seconds')::interval, now(), 0, '{}'::jsonb)
        ON CONFLICT (user_id) DO UPDATE SET
          app_id = EXCLUDED.app_id,
          latitude = EXCLUDED.latitude,
          longitude = EXCLUDED.longitude,
          accuracy_m = EXCLUDED.accuracy_m,
          expires_at = EXCLUDED.expires_at,
          updated_at = EXCLUDED.updated_at,
          -- A MATERIAL move advances the fix and drops every pin minted against the old one; a
          -- stationary re-publish keeps both, so republishing cannot be used to shake a pin loose.
          fix_seq = CASE WHEN $7 THEN nearby_presence.fix_seq + 1 ELSE nearby_presence.fix_seq END,
          pins = CASE WHEN $7 THEN '{}'::jsonb ELSE nearby_presence.pins END
        """,
        [user_id, app_id, latitude, longitude, accuracy, presence_seconds_param(),
         advance?]
      )

      {:ok, %{published: true, expires_in_seconds: @presence_seconds}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
    _error in Postgrex.Error -> {:error, :nearby_invalid}
  end

  defp previous_fix(user_id) do
    case Repo.query!(
           "SELECT latitude, longitude FROM nearby_presence " <>
             "WHERE user_id = $1::text::uuid AND expires_at > now()",
           [user_id]
         ) do
      %{rows: [[lat, lng]]} when is_number(lat) and is_number(lng) -> {lat, lng}
      _ -> nil
    end
  end

  defp require_publish_allowed(user_id) do
    case settings_row(user_id) do
      %{enabled: true, auto_publish: true} = settings -> {:ok, settings}
      %{enabled: true} -> {:error, :nearby_publish_disabled}
      _ -> {:error, :nearby_disabled}
    end
  end

  # Metres between two WGS84 points. Mirrors the discover query's in-SQL haversine so the
  # move threshold and the distance bucket cannot disagree about what "25 m" means.
  defp haversine_m(lat1, lng1, lat2, lng2) do
    r = 6_371_000.0
    dlat = :math.pi() * (lat2 - lat1) / 180.0
    dlng = :math.pi() * (lng2 - lng1) / 180.0
    rlat1 = :math.pi() * lat1 / 180.0
    rlat2 = :math.pi() * lat2 / 180.0

    a =
      :math.pow(:math.sin(dlat / 2.0), 2) +
        :math.cos(rlat1) * :math.cos(rlat2) * :math.pow(:math.sin(dlng / 2.0), 2)

    2.0 * r * :math.asin(min(1.0, :math.sqrt(a)))
  end

  def stop(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id") do
      Repo.query!(
        "DELETE FROM nearby_presence WHERE user_id = $1::text::uuid OR expires_at < now()",
        [user_id]
      )

      {:ok, %{discoverable: false}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
  end

  def send_request(attrs) do
    with {:ok, requester} <- required(attrs, "requester_user_id"),
         {:ok, recipient} <- required(attrs, "recipient_user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         :ok <- not_self(requester, recipient) do
      case Repo.transaction(fn -> create_request(requester, recipient, app_id) end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
    _error in Postgrex.Error -> {:error, :nearby_invalid}
  end

  defp create_request(requester, recipient, app_id) do
    %{rows: eligible} =
      Repo.query!(
        """
        SELECT 1
        FROM nearby_presence mine
        JOIN nearby_presence theirs ON theirs.user_id = $2::text::uuid
        JOIN users_auth target ON target.id = theirs.user_id AND target.status = 'active'
        WHERE mine.user_id = $1::text::uuid
          AND mine.app_id = $3::text::uuid
          AND theirs.app_id = $3::text::uuid
          AND mine.expires_at > now() AND theirs.expires_at > now()
          AND target.app_id = $3::text::uuid
          AND 6371000.0 * 2.0 * asin(LEAST(1.0, sqrt(
                power(sin(radians((theirs.latitude - mine.latitude) / 2.0)), 2) +
                cos(radians(mine.latitude)) * cos(radians(theirs.latitude)) *
                power(sin(radians((theirs.longitude - mine.longitude) / 2.0)), 2)
              ))) <= 200
          -- STORE-LEVEL block exclusion (defense-in-depth, mirrors discover): a blocked pair fails
          -- eligibility outright — same :nearby_not_discoverable as any other miss, no block leak.
          AND NOT EXISTS (
            SELECT 1 FROM user_blocks ub
            WHERE (ub.blocker_user_id = $1::text::uuid AND ub.blocked_user_id = $2::text::uuid)
               OR (ub.blocker_user_id = $2::text::uuid AND ub.blocked_user_id = $1::text::uuid)
          )
        """,
        [requester, recipient, app_id]
      )

    if eligible == [], do: Repo.rollback(:nearby_not_discoverable)

    # DECLINE COOLDOWN (audit fix 4): a decline holds for 24h against the SAME direction — the
    # declined side may still reach out the other way (that is an explicit choice, not spam).
    %{rows: [[cooling]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM nearby_connection_requests
          WHERE app_id = $3::text::uuid
            AND requester_user_id = $1::text::uuid
            AND recipient_user_id = $2::text::uuid
            AND status = 'declined'
            AND responded_at > now() - interval '24 hours'
        )
        """,
        [requester, recipient, app_id]
      )

    if cooling, do: Repo.rollback(:nearby_request_cooldown)

    %{rows: [[connected]]} =
      Repo.query!(
        """
        SELECT EXISTS (
          SELECT 1 FROM nearby_connections
          WHERE app_id = $3::text::uuid
            AND user_low_id = LEAST($1::text::uuid, $2::text::uuid)
            AND user_high_id = GREATEST($1::text::uuid, $2::text::uuid)
        )
        """,
        [requester, recipient, app_id]
      )

    if connected, do: Repo.rollback(:nearby_already_connected)

    case Repo.query(
           """
           INSERT INTO nearby_connection_requests
             (app_id, requester_user_id, recipient_user_id)
           VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid)
           RETURNING id::text, created_at
           """,
           [app_id, requester, recipient]
         ) do
      {:ok, %{rows: [[id, created_at]]}} ->
        %{request_id: id, status: "pending", created_at: iso(created_at)}

      {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} ->
        Repo.rollback(:nearby_request_exists)
    end
  end

  def list_requests(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id") do
      %{rows: incoming} =
        Repo.query!(
          "SELECT id::text, requester_user_id::text, created_at FROM nearby_connection_requests " <>
            "WHERE app_id = $2::text::uuid AND recipient_user_id = $1::text::uuid " <>
            "AND status = 'pending' ORDER BY created_at DESC LIMIT 50",
          [user_id, app_id]
        )

      %{rows: outgoing} =
        Repo.query!(
          "SELECT id::text, recipient_user_id::text, created_at FROM nearby_connection_requests " <>
            "WHERE app_id = $2::text::uuid AND requester_user_id = $1::text::uuid " <>
            "AND status = 'pending' ORDER BY created_at DESC LIMIT 50",
          [user_id, app_id]
        )

      %{rows: connections} =
        Repo.query!(
          """
          SELECT CASE WHEN user_low_id = $1::text::uuid THEN user_high_id::text
                      ELSE user_low_id::text END, connected_at
          FROM nearby_connections
          WHERE app_id = $2::text::uuid
            AND (user_low_id = $1::text::uuid OR user_high_id = $1::text::uuid)
          ORDER BY connected_at DESC LIMIT 100
          """,
          [user_id, app_id]
        )

      {:ok,
       %{
         incoming: request_rows(incoming),
         outgoing: request_rows(outgoing),
         connections:
           Enum.map(connections, fn [id, at] -> %{user_id: id, connected_at: iso(at)} end)
       }}
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
  end

  def respond(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, request_id} <- required(attrs, "request_id"),
         {:ok, decision} <- decision(attrs) do
      case Repo.transaction(fn -> respond_to_request(user_id, request_id, decision) end) do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
  end

  defp respond_to_request(user_id, request_id, decision) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT app_id::text, requester_user_id::text, recipient_user_id::text
        FROM nearby_connection_requests
        WHERE id = $1::text::uuid AND recipient_user_id = $2::text::uuid AND status = 'pending'
        FOR UPDATE
        """,
        [request_id, user_id]
      )

    case rows do
      [[app_id, requester, recipient]] ->
        status = if decision == "accept", do: "accepted", else: "declined"

        Repo.query!(
          "UPDATE nearby_connection_requests SET status = $3, responded_at = now() " <>
            "WHERE id = $1::text::uuid AND recipient_user_id = $2::text::uuid",
          [request_id, user_id, status]
        )

        if status == "accepted" do
          Repo.query!(
            "INSERT INTO nearby_connections (app_id, user_low_id, user_high_id) " <>
              "VALUES ($1::text::uuid, LEAST($2::text::uuid, $3::text::uuid), " <>
              "GREATEST($2::text::uuid, $3::text::uuid)) ON CONFLICT DO NOTHING",
            [app_id, requester, recipient]
          )
        end

        %{request_id: request_id, status: status, user_id: requester}

      [] ->
        Repo.rollback(:nearby_request_not_found)
    end
  end

  @doc """
  BLE sighting admission (104), the STORE-LEVEL wall — the gateway resolves tokens, this decides
  which resolved pairs may become proximity markers. In ONE query per call: the viewer must have a
  LIVE presence row (BLE assists discovery, never lurk-mode) and each candidate survives only if
  same-app + active, not self, not blocked (either direction), target enabled, and audience admits
  BOTH ways. Returns the admitted ids — a dropped candidate is indistinguishable from an unknown
  token upstream (the response is a count either way).
  """
  def admit_ble_targets(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, targets} <- target_list(attrs),
         {:ok, viewer} <- require_enabled(user_id) do
      %{rows: [[live]]} =
        Repo.query!(
          "SELECT EXISTS (SELECT 1 FROM nearby_presence " <>
            "WHERE user_id = $1::text::uuid AND app_id = $2::text::uuid AND expires_at > now())",
          [user_id, app_id]
        )

      if live do
        %{rows: rows} =
          Repo.query!(
            """
            SELECT c.id::text
            FROM (SELECT DISTINCT (t.cand)::uuid AS id FROM unnest($3::text[]) AS t(cand)) c
            JOIN users_auth a ON a.id = c.id AND a.app_id = $2::text::uuid AND a.status = 'active'
            WHERE c.id <> $1::text::uuid
              AND NOT EXISTS (
                SELECT 1 FROM user_blocks ub
                WHERE (ub.blocker_user_id = $1::text::uuid AND ub.blocked_user_id = c.id)
                   OR (ub.blocker_user_id = c.id AND ub.blocked_user_id = $1::text::uuid)
              )
              AND COALESCE((SELECT s.enabled FROM nearby_settings s WHERE s.user_id = c.id), true)
              AND (COALESCE((SELECT s.audience FROM nearby_settings s WHERE s.user_id = c.id),
                            'everyone') = 'everyone'
                   OR EXISTS (SELECT 1 FROM favourite_contacts tf
                              WHERE tf.owner_user_id = c.id
                                AND tf.favourite_user_id = $1::text::uuid))
              AND ($4 = 'everyone'
                   OR EXISTS (SELECT 1 FROM favourite_contacts vf
                              WHERE vf.owner_user_id = $1::text::uuid
                                AND vf.favourite_user_id = c.id))
            """,
            [user_id, app_id, targets, viewer.audience]
          )

        {:ok, %{admitted: Enum.map(rows, fn [id] -> id end)}}
      else
        # Distinct from :nearby_not_discoverable — this is "YOU are not sharing", not "they left".
        {:error, :nearby_presence_required}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :nearby_invalid}
    _error in Postgrex.Error -> {:error, :nearby_invalid}
  end

  # --- settings internals ------------------------------------------------------------------------

  # THE DEFAULTS ARE THE CONTRACT. An absent row means "discoverable while I have Nearby open" —
  # enabled true, auto_publish FALSE. Adding auto_publish here with a false default is what makes 114
  # change nobody's exposure on its own.
  defp settings_row(user_id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT enabled, ble_assist, audience, auto_publish FROM nearby_settings " <>
          "WHERE user_id = $1::text::uuid",
        [user_id]
      )

    case rows do
      [[enabled, ble_assist, audience, auto_publish]] ->
        %{
          enabled: enabled,
          ble_assist: ble_assist,
          audience: audience,
          auto_publish: auto_publish
        }

      [] ->
        %{enabled: true, ble_assist: false, audience: "everyone", auto_publish: false}
    end
  end

  defp require_enabled(user_id) do
    case settings_row(user_id) do
      %{enabled: true} = settings -> {:ok, settings}
      _ -> {:error, :nearby_disabled}
    end
  end

  # Booleans matched EXPLICITLY — `false` is a value, absent is nil. The module's shared `get/2`
  # helper is exactly the falsy-mget trap (`Map.get(m, "k") || Map.get(m, :k)` reads a stored false
  # as absent), so booleans must never go through it — caught red in the settings test.
  defp optional_bool(attrs, key, atom_key) do
    value =
      case Map.fetch(attrs, key) do
        {:ok, found} -> found
        :error -> Map.get(attrs, atom_key)
      end

    case value do
      nil -> {:ok, nil}
      boolean when is_boolean(boolean) -> {:ok, boolean}
      _ -> {:error, :nearby_invalid}
    end
  end

  defp optional_audience(attrs) do
    case get(attrs, "audience") do
      nil -> {:ok, nil}
      value when value in @audiences -> {:ok, value}
      _ -> {:error, :nearby_invalid}
    end
  end

  defp target_list(attrs) do
    case get(attrs, "targets") do
      list when is_list(list) and length(list) <= 20 ->
        if Enum.all?(list, &(is_binary(&1) and match?({:ok, _}, Ecto.UUID.cast(&1)))),
          do: {:ok, list},
          else: {:error, :nearby_invalid}

      _ ->
        {:error, :nearby_invalid}
    end
  end

  defp request_rows(rows) do
    Enum.map(rows, fn [request_id, user_id, created_at] ->
      %{request_id: request_id, user_id: user_id, created_at: iso(created_at)}
    end)
  end

  defp pinned_or_computed(pinned, distance) do
    case pinned do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {bucket, ""} when bucket in [100, 200] -> bucket
          _ -> distance_bucket(distance)
        end

      _ ->
        distance_bucket(distance)
    end
  end

  # 100/200 ONLY — the 50 m bucket was dropped (audit 2026-08-26): sub-100 m resolution plus live
  # refresh is boundary-walkable even with pinning as belt-and-braces.
  defp distance_bucket(distance) do
    value = if is_struct(distance, Decimal), do: Decimal.to_float(distance), else: distance * 1.0
    if value <= 100, do: 100, else: 200
  end

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :nearby_invalid}
    end
  end

  defp coordinate(attrs, key, min, max) do
    case number(get(attrs, key)) do
      value when is_float(value) and value >= min and value <= max -> {:ok, value}
      _ -> {:error, :nearby_invalid}
    end
  end

  defp accuracy(attrs) do
    case number(get(attrs, "accuracy_m")) do
      value when is_float(value) and value >= 0 and value <= 100 -> {:ok, value}
      _ -> {:error, :nearby_accuracy_too_low}
    end
  end

  defp radius(attrs) do
    value = get(attrs, "radius_m")

    parsed =
      if is_binary(value) do
        case Integer.parse(value) do
          {number, ""} -> number
          _ -> nil
        end
      else
        value
      end

    if parsed in @valid_radii, do: {:ok, parsed}, else: {:error, :nearby_invalid}
  end

  defp decision(attrs) do
    case get(attrs, "decision") do
      value when value in ["accept", "decline"] -> {:ok, value}
      _ -> {:error, :nearby_invalid}
    end
  end

  defp not_self(id, id), do: {:error, :nearby_invalid}
  defp not_self(_, _), do: :ok

  defp number(value) when is_integer(value), do: value * 1.0
  defp number(value) when is_float(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp number(_), do: nil

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp iso(value), do: to_string(value)
end

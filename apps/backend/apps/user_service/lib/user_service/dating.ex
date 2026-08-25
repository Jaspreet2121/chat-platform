defmodule UserService.Dating do
  @moduledoc """
  Dating (105) — a separate OPT-IN section, isolated by construction: its own tables, its own card
  (never ProfilePresenter), and no other surface reads them. The location is a CHOSEN point, not
  live GPS.

  Age is computed from dob server-side on every read — never stored, never trusted from a client.
  Enabling hard-requires dob/gender/interested_in/≥2 owner-verified photos/location, and refuses
  under-18 outright. dob is immutable once set except ONE correction within 48h (logged).

  The MATCH is race-safe the claim-precedent way: the swipe transaction takes a pair-scoped
  advisory xact lock, so concurrent mutual likes serialize — exactly one dating_matches row
  (the unique unordered-pair index is the backstop, ON CONFLICT DO NOTHING + guaranteed re-select,
  the allocate_twin shape). The 1:1 conversation is created-or-got AT THE GATEWAY through the same
  path every DM uses (the nearby accept precedent) and attached here afterwards — best-effort,
  because find-or-create makes a later attach safe and a conversation-service hiccup must never
  roll back a committed match.
  """

  alias UserService.Repo

  @genders ~w(woman man nonbinary other)
  @bio_max 500
  @max_photos 6
  @min_photos_to_enable 2
  @deck_limit_max 25
  @page_limit 25
  @dob_correction_window_seconds 48 * 3600

  # ---- profile ----------------------------------------------------------------------------------

  def get_profile(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id") do
      {:ok, profile_row(user_id)}
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
  end

  @doc """
  Partial PATCH. Validation is strict at write; the ENABLE gate (all required fields + adult age)
  re-checks the MERGED state so a client can never enable a half profile. Photos are owner-verified
  against media_assets in the same transaction. Disabling flips one flag — every deck/likes query
  gates on `enabled`, so removal is instant; data is retained.
  """
  def update_profile(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, updates} <- validate_updates(attrs) do
      Repo.transaction(fn ->
        current = profile_row(user_id)

        with :ok <- check_dob_rules(current, updates),
             :ok <- check_photos_owned(user_id, app_id, updates[:photos]),
             merged = merge_state(current, updates),
             :ok <- check_enable_gate(merged, updates) do
          upsert_profile(user_id, app_id, updates)
          profile_row(user_id)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, profile} -> {:ok, profile}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
    _error in Postgrex.Error -> {:error, :dating_invalid}
  end

  # ---- deck -------------------------------------------------------------------------------------

  @doc """
  The swipe deck: candidates where BOTH sides' constraints hold — mutual gender/interest, each
  inside the other's age range, distance ≤ the SMALLER of the two max_distance_km (a bounding-box
  latitude prefilter then exact haversine), same app, both enabled, not self, not blocked either
  direction (store-level), no swipe BY ME (their pass on me does NOT hide them from me), no match.
  Ordered by dating recency with a random tiebreak. Cards carry rounded km — never coordinates.
  """
  def deck(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, me} <- require_enabled(user_id) do
      limit = attrs |> limit_of(@deck_limit_max) |> min(@deck_limit_max)
      touch_activity(user_id)

      %{rows: rows} =
        Repo.query!(
          """
          SELECT p.user_id::text, up.display_name,
                 EXTRACT(YEAR FROM age(p.dob))::int AS age, p.bio,
                 ARRAY(SELECT ph::text FROM unnest(p.photos) ph) AS photos,
                 ROUND(6371.0 * 2.0 * asin(LEAST(1.0, sqrt(
                   power(sin(radians((p.latitude - $3) / 2.0)), 2) +
                   cos(radians($3)) * cos(radians(p.latitude)) *
                   power(sin(radians((p.longitude - $4) / 2.0)), 2)
                 ))))::int AS distance_km
          FROM dating_profiles p
          JOIN users_auth a ON a.id = p.user_id AND a.status = 'active'
          LEFT JOIN user_profiles up ON up.user_id = p.user_id
          WHERE p.app_id = $2::text::uuid
            AND p.user_id <> $1::text::uuid
            AND p.enabled
            AND p.dob IS NOT NULL AND p.latitude IS NOT NULL AND p.longitude IS NOT NULL
            -- mutual gender/interest, BOTH directions
            AND p.gender = ANY($5::text[])
            AND $6 = ANY(p.interested_in)
            -- deck-only narrowing ('{}' = follow interested_in)
            AND ($7::text[] = '{}'::text[] OR p.gender = ANY($7::text[]))
            -- age fits BOTH ways
            AND EXTRACT(YEAR FROM age(p.dob))::int BETWEEN $8 AND $9
            AND $10 BETWEEN p.min_age AND p.max_age
            -- latitude band prefilter (deck_idx), then the exact great-circle test below
            AND p.latitude BETWEEN $3 - ($11 / 111.0) AND $3 + ($11 / 111.0)
            AND 6371.0 * 2.0 * asin(LEAST(1.0, sqrt(
                  power(sin(radians((p.latitude - $3) / 2.0)), 2) +
                  cos(radians($3)) * cos(radians(p.latitude)) *
                  power(sin(radians((p.longitude - $4) / 2.0)), 2)
                ))) <= LEAST($11::double precision, p.max_distance_km::double precision)
            -- blocks, either direction — store level
            AND NOT EXISTS (
              SELECT 1 FROM user_blocks ub
              WHERE (ub.blocker_user_id = $1::text::uuid AND ub.blocked_user_id = p.user_id)
                 OR (ub.blocker_user_id = p.user_id AND ub.blocked_user_id = $1::text::uuid)
            )
            -- MY swipe hides; THEIR pass on me does not
            AND NOT EXISTS (
              SELECT 1 FROM dating_swipes s
              WHERE s.app_id = $2::text::uuid
                AND s.swiper_id = $1::text::uuid AND s.target_id = p.user_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM dating_matches m
              WHERE m.app_id = $2::text::uuid
                AND m.user_low_id = LEAST($1::text::uuid, p.user_id)
                AND m.user_high_id = GREATEST($1::text::uuid, p.user_id)
            )
          ORDER BY p.last_active_at DESC, random()
          LIMIT #{@deck_limit_max}
          """,
          [
            user_id,
            app_id,
            me.latitude,
            me.longitude,
            me.interested_in,
            me.gender,
            me.pref_genders,
            me.min_age,
            me.max_age,
            age_of(me.dob),
            me.max_distance_km * 1.0
          ]
        )

      {:ok, %{cards: rows |> Enum.take(limit) |> Enum.map(&card_row/1)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
    _error in Postgrex.Error -> {:error, :dating_invalid}
  end

  # ---- swipes -----------------------------------------------------------------------------------

  @doc """
  Upsert my swipe under a PAIR-SCOPED advisory xact lock (concurrent mutual likes serialize; the
  unique pair index is the backstop). like→pass only while unmatched (a matched pair must unmatch).
  A like meeting an existing reverse like creates the match IN THIS TRANSACTION and reports it;
  the conversation is attached by the gateway afterwards (see moduledoc).
  """
  def swipe(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, target_id} <- required(attrs, "target_id"),
         {:ok, action} <- action_of(attrs),
         :ok <- not_self(user_id, target_id),
         {:ok, _me} <- require_enabled(user_id) do
      Repo.transaction(fn ->
        lock_pair(app_id, user_id, target_id)

        existing_match = match_of_pair(app_id, user_id, target_id)

        cond do
          existing_match != nil and action == "pass" ->
            Repo.rollback(:dating_matched)

          existing_match != nil ->
            # Already matched; a repeated like is idempotent and re-reports the match.
            Map.put(existing_match, :matched, true)

          true ->
            upsert_swipe(app_id, user_id, target_id, action)

            if action == "like" and reverse_like?(app_id, user_id, target_id) do
              app_id |> create_match(user_id, target_id) |> Map.put(:matched, true)
            else
              %{matched: false}
            end
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
    _error in Postgrex.Error -> {:error, :dating_invalid}
  end

  @doc false
  # Public (doc false, the allocate_twin precedent) so the raced-loser branch is provable: INSERT
  # ON CONFLICT DO NOTHING returns zero rows exactly when the pair row already exists, and the
  # guaranteed follow-up SELECT is load-bearing.
  def create_match(app_id, user_a, user_b) do
    case Repo.query!(
           "INSERT INTO dating_matches (app_id, user_low_id, user_high_id) " <>
             "VALUES ($1::text::uuid, LEAST($2::text::uuid, $3::text::uuid), " <>
             "GREATEST($2::text::uuid, $3::text::uuid)) " <>
             "ON CONFLICT (app_id, user_low_id, user_high_id) DO NOTHING " <>
             "RETURNING id::text, conversation_id::text",
           [app_id, user_a, user_b]
         ) do
      %{rows: [[id, conversation_id]]} ->
        %{match_id: id, conversation_id: conversation_id}

      %{rows: []} ->
        match_of_pair(app_id, user_a, user_b) ||
          raise "dating match vanished under the pair lock"
    end
  end

  @doc "Stamp the created-or-got conversation onto a match (gateway calls this after the create)."
  def attach_match_conversation(attrs) do
    with {:ok, match_id} <- required(attrs, "match_id"),
         {:ok, conversation_id} <- required(attrs, "conversation_id") do
      Repo.query!(
        "UPDATE dating_matches SET conversation_id = $2::text::uuid " <>
          "WHERE id = $1::text::uuid AND conversation_id IS NULL",
        [match_id, conversation_id]
      )

      {:ok, %{attached: true}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
  end

  # ---- likes ------------------------------------------------------------------------------------

  @doc """
  Who liked me: reverse likes with NO swipe by me (my pass hides the row from MY list forever and
  never notifies the liker), both still enabled, same app, unblocked (store level). Same card
  shape as the deck. Keyset cursor (updated_at, id).
  """
  def likes(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, me} <- require_enabled(user_id),
         {:ok, cursor} <- cursor_of(attrs) do
      {cursor_ts, cursor_id} = cursor || {nil, nil}

      %{rows: rows} =
        Repo.query!(
          """
          SELECT p.user_id::text, up.display_name,
                 EXTRACT(YEAR FROM age(p.dob))::int AS age, p.bio,
                 ARRAY(SELECT ph::text FROM unnest(p.photos) ph) AS photos,
                 ROUND(6371.0 * 2.0 * asin(LEAST(1.0, sqrt(
                   power(sin(radians((p.latitude - $3) / 2.0)), 2) +
                   cos(radians($3)) * cos(radians(p.latitude)) *
                   power(sin(radians((p.longitude - $4) / 2.0)), 2)
                 ))))::int AS distance_km,
                 s.updated_at, s.id::text
          FROM dating_swipes s
          JOIN dating_profiles p ON p.user_id = s.swiper_id AND p.enabled
          JOIN users_auth a ON a.id = s.swiper_id AND a.status = 'active'
          LEFT JOIN user_profiles up ON up.user_id = s.swiper_id
          WHERE s.app_id = $2::text::uuid AND s.target_id = $1::text::uuid AND s.action = 'like'
            AND NOT EXISTS (
              SELECT 1 FROM dating_swipes mine
              WHERE mine.app_id = $2::text::uuid
                AND mine.swiper_id = $1::text::uuid AND mine.target_id = s.swiper_id
            )
            AND NOT EXISTS (
              SELECT 1 FROM user_blocks ub
              WHERE (ub.blocker_user_id = $1::text::uuid AND ub.blocked_user_id = s.swiper_id)
                 OR (ub.blocker_user_id = s.swiper_id AND ub.blocked_user_id = $1::text::uuid)
            )
            AND ($5::timestamptz IS NULL OR (s.updated_at, s.id) < ($5::timestamptz, $6::uuid))
          ORDER BY s.updated_at DESC, s.id DESC
          LIMIT #{@page_limit}
          """,
          [user_id, app_id, me.latitude, me.longitude, cursor_ts, cursor_id]
        )

      cards = Enum.map(rows, fn row -> card_row(Enum.take(row, 6)) end)
      {:ok, %{cards: cards, next_cursor: next_cursor(rows)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
    _error in Postgrex.Error -> {:error, :dating_invalid}
  end

  # ---- matches ----------------------------------------------------------------------------------

  @doc """
  My matches (peer card + conversation_id + matched_at), newest first, keyset cursor. Matches stay
  visible when a peer DISABLES dating (an established relationship, and the chat persists) but are
  hidden while BLOCKED either way (store level — the gateway block hook also hard-unmatches).
  """
  def matches(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, cursor} <- cursor_of(attrs) do
      {cursor_ts, cursor_id} = cursor || {nil, nil}
      me = profile_row(user_id)

      %{rows: rows} =
        Repo.query!(
          """
          SELECT peer.user_id::text, up.display_name,
                 EXTRACT(YEAR FROM age(peer.dob))::int AS age, peer.bio,
                 ARRAY(SELECT ph::text FROM unnest(peer.photos) ph) AS photos,
                 ROUND(6371.0 * 2.0 * asin(LEAST(1.0, sqrt(
                   power(sin(radians((peer.latitude - $3) / 2.0)), 2) +
                   cos(radians($3)) * cos(radians(peer.latitude)) *
                   power(sin(radians((peer.longitude - $4) / 2.0)), 2)
                 ))))::int AS distance_km,
                 m.matched_at, m.id::text, m.conversation_id::text
          FROM dating_matches m
          JOIN dating_profiles peer
            ON peer.user_id = CASE WHEN m.user_low_id = $1::text::uuid
                                   THEN m.user_high_id ELSE m.user_low_id END
          LEFT JOIN user_profiles up ON up.user_id = peer.user_id
          WHERE m.app_id = $2::text::uuid
            AND (m.user_low_id = $1::text::uuid OR m.user_high_id = $1::text::uuid)
            AND NOT EXISTS (
              SELECT 1 FROM user_blocks ub
              WHERE (ub.blocker_user_id = $1::text::uuid AND ub.blocked_user_id = peer.user_id)
                 OR (ub.blocker_user_id = peer.user_id AND ub.blocked_user_id = $1::text::uuid)
            )
            AND ($5::timestamptz IS NULL OR (m.matched_at, m.id) < ($5::timestamptz, $6::uuid))
          ORDER BY m.matched_at DESC, m.id DESC
          LIMIT #{@page_limit}
          """,
          [user_id, app_id, me[:latitude], me[:longitude], cursor_ts, cursor_id]
        )

      matches =
        Enum.map(rows, fn row ->
          [matched_at, match_id, conversation_id] = Enum.drop(row, 6)

          row
          |> Enum.take(6)
          |> card_row()
          |> Map.merge(%{
            match_id: match_id,
            conversation_id: conversation_id,
            matched_at: iso(matched_at)
          })
        end)

      {:ok, %{matches: matches, next_cursor: next_cursor(rows)}}
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
    _error in Postgrex.Error -> {:error, :dating_invalid}
  end

  @doc """
  Unmatch: remove the match row (caller must be a member) and DELETE both swipe rows — reset to
  none, so neither reappears in the other's likes and both may resurface in decks. The
  CONVERSATION IS LEFT INTACT (recorded decision: deleting chats is destructive; the pair keeps
  their history and can delete the chat themselves). Returns the peer for the gateway's broadcast.
  """
  def unmatch(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, match_id} <- required(attrs, "match_id") do
      Repo.transaction(fn ->
        %{rows: rows} =
          Repo.query!(
            "DELETE FROM dating_matches WHERE id = $1::text::uuid AND app_id = $2::text::uuid " <>
              "AND (user_low_id = $3::text::uuid OR user_high_id = $3::text::uuid) " <>
              "RETURNING user_low_id::text, user_high_id::text",
            [match_id, app_id, user_id]
          )

        case rows do
          [[low, high]] ->
            delete_pair_swipes(app_id, low, high)
            %{unmatched: true, peer_user_id: if(low == user_id, do: high, else: low)}

          [] ->
            Repo.rollback(:dating_match_not_found)
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
  end

  @doc """
  Block hook (gateway calls after a successful block): if the PAIR is matched, hard-unmatch —
  same semantics as unmatch/1. {:ok, %{unmatched, match_id}} — match_id nil when nothing existed.
  """
  def unmatch_pair(attrs) do
    with {:ok, user_id} <- required(attrs, "user_id"),
         {:ok, app_id} <- required(attrs, "app_id"),
         {:ok, peer_id} <- required(attrs, "peer_user_id") do
      Repo.transaction(fn ->
        %{rows: rows} =
          Repo.query!(
            "DELETE FROM dating_matches WHERE app_id = $1::text::uuid " <>
              "AND user_low_id = LEAST($2::text::uuid, $3::text::uuid) " <>
              "AND user_high_id = GREATEST($2::text::uuid, $3::text::uuid) RETURNING id::text",
            [app_id, user_id, peer_id]
          )

        case rows do
          [[match_id]] ->
            delete_pair_swipes(app_id, user_id, peer_id)
            %{unmatched: true, match_id: match_id}

          [] ->
            %{unmatched: false, match_id: nil}
        end
      end)
      |> case do
        {:ok, result} -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  rescue
    Ecto.Query.CastError -> {:error, :dating_invalid}
  end

  # ---- internals --------------------------------------------------------------------------------

  defp profile_row(user_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT enabled, dob::text, dob_set_at, dob_corrected_at, gender, interested_in, bio,
               ARRAY(SELECT ph::text FROM unnest(photos) ph), latitude, longitude, location_name,
               min_age, max_age, max_distance_km, pref_genders
        FROM dating_profiles WHERE user_id = $1::text::uuid
        """,
        [user_id]
      )

    case rows do
      [
        [
          enabled,
          dob,
          dob_set_at,
          dob_corrected_at,
          gender,
          interested_in,
          bio,
          photos,
          latitude,
          longitude,
          location_name,
          min_age,
          max_age,
          max_distance_km,
          pref_genders
        ]
      ] ->
        %{
          enabled: enabled,
          dob: dob,
          dob_set_at: dob_set_at,
          dob_corrected_at: dob_corrected_at,
          gender: gender,
          interested_in: interested_in,
          bio: bio,
          photos: photos,
          latitude: latitude,
          longitude: longitude,
          location_name: location_name,
          min_age: min_age,
          max_age: max_age,
          max_distance_km: max_distance_km,
          pref_genders: pref_genders,
          age: age_of(dob)
        }

      [] ->
        %{
          enabled: false,
          dob: nil,
          dob_set_at: nil,
          dob_corrected_at: nil,
          gender: nil,
          interested_in: [],
          bio: nil,
          photos: [],
          latitude: nil,
          longitude: nil,
          location_name: nil,
          min_age: 18,
          max_age: 100,
          max_distance_km: 100,
          pref_genders: [],
          age: nil
        }
    end
  end

  defp require_enabled(user_id) do
    case profile_row(user_id) do
      %{enabled: true} = me -> {:ok, me}
      _ -> {:error, :dating_disabled}
    end
  end

  defp card_row([user_id, display_name, age, bio, photos, distance_km]) do
    %{
      user_id: user_id,
      # First word of the chat display name — dating convention: first names, never handles.
      display_name: first_word(display_name),
      age: age,
      bio: bio,
      photos: photos || [],
      distance_km: distance_km
    }
  end

  defp first_word(nil), do: nil
  defp first_word(name), do: name |> String.split(" ", parts: 2) |> hd()

  defp age_of(nil), do: nil

  defp age_of(dob) when is_binary(dob) do
    case Date.from_iso8601(dob) do
      {:ok, date} -> age_of(date)
      _ -> nil
    end
  end

  defp age_of(%Date{} = dob) do
    today = Date.utc_today()
    years = today.year - dob.year
    birthday_passed? = {today.month, today.day} >= {dob.month, dob.day}
    if birthday_passed?, do: years, else: years - 1
  end

  # -- validation --

  defp validate_updates(attrs) do
    with {:ok, enabled} <- opt_bool(attrs, "enabled", :enabled),
         {:ok, dob} <- opt_dob(attrs),
         {:ok, gender} <- opt_gender(attrs),
         {:ok, interested_in} <- opt_genders_list(attrs, "interested_in", _min = 1),
         {:ok, bio} <- opt_bio(attrs),
         {:ok, photos} <- opt_photos(attrs),
         {:ok, location} <- opt_location(attrs),
         {:ok, prefs} <- opt_prefs(attrs) do
      {:ok,
       %{
         enabled: enabled,
         dob: dob,
         gender: gender,
         interested_in: interested_in,
         bio: bio,
         photos: photos,
         location: location,
         prefs: prefs
       }}
    end
  end

  defp check_dob_rules(current, %{dob: new_dob}) when not is_nil(new_dob) do
    cond do
      current.dob == nil -> :ok
      current.dob == new_dob -> :ok
      current.dob_corrected_at != nil -> {:error, :dating_dob_locked}
      outside_correction_window?(current.dob_set_at) -> {:error, :dating_dob_locked}
      true -> :ok
    end
  end

  defp check_dob_rules(_current, _updates), do: :ok

  defp outside_correction_window?(nil), do: false

  defp outside_correction_window?(%DateTime{} = set_at),
    do: DateTime.diff(DateTime.utc_now(), set_at) > @dob_correction_window_seconds

  defp outside_correction_window?(%NaiveDateTime{} = set_at),
    do: NaiveDateTime.diff(NaiveDateTime.utc_now(), set_at) > @dob_correction_window_seconds

  defp check_photos_owned(_user_id, _app_id, nil), do: :ok
  defp check_photos_owned(_user_id, _app_id, []), do: :ok

  defp check_photos_owned(user_id, app_id, photos) do
    %{rows: [[owned]]} =
      Repo.query!(
        "SELECT count(*)::int FROM media_assets " <>
          "WHERE id = ANY(($3::text[])::uuid[]) AND owner_user_id = $1::text::uuid AND app_id = $2::text::uuid",
        [user_id, app_id, photos]
      )

    if owned == length(Enum.uniq(photos)), do: :ok, else: {:error, :dating_photo_not_owned}
  end

  # The state the profile WOULD have after this PATCH — what the enable gate judges.
  defp merge_state(current, updates) do
    %{
      enabled: if(updates.enabled != nil, do: updates.enabled, else: current.enabled),
      dob: updates.dob || current.dob,
      gender: updates.gender || current.gender,
      interested_in: updates.interested_in || current.interested_in,
      photos: updates.photos || current.photos,
      latitude: (updates.location && updates.location.lat) || current.latitude,
      min_age: (updates.prefs && updates.prefs[:min_age]) || current.min_age
    }
  end

  defp check_enable_gate(merged, updates) do
    cond do
      # Age is checked whenever a dob is present in the final state — an under-18 dob is refused
      # even while disabled (never stored as an enable-ready value).
      merged.dob != nil and age_of(merged.dob) < 18 ->
        {:error, :dating_underage}

      merged.enabled != true ->
        :ok

      merged.dob == nil or merged.gender == nil or merged.interested_in == [] or
        merged.latitude == nil or length(merged.photos) < @min_photos_to_enable ->
        {:error, :dating_profile_incomplete}

      true ->
        _ = updates
        :ok
    end
  end

  defp upsert_profile(user_id, app_id, updates) do
    location = updates.location
    prefs = updates.prefs

    Repo.query!(
      """
      INSERT INTO dating_profiles
        (user_id, app_id, enabled, dob, dob_set_at, gender, interested_in, bio, photos,
         latitude, longitude, location_name, min_age, max_age, max_distance_km, pref_genders,
         last_active_at, updated_at)
      VALUES ($1::text::uuid, $2::text::uuid, COALESCE($3, false), ($4::text)::date,
              CASE WHEN ($4::text)::date IS NOT NULL THEN now() END,
              $5, COALESCE($6::text[], '{}'), $7, COALESCE(($8::text[])::uuid[], '{}'),
              $9, $10, $11, COALESCE($12, 18), COALESCE($13, 100), COALESCE($14, 100),
              COALESCE($15::text[], '{}'), now(), now())
      ON CONFLICT (user_id) DO UPDATE SET
        app_id = EXCLUDED.app_id,
        enabled = COALESCE($3, dating_profiles.enabled),
        dob = COALESCE(($4::text)::date, dating_profiles.dob),
        dob_set_at = CASE WHEN dating_profiles.dob IS NULL AND ($4::text)::date IS NOT NULL THEN now()
                          ELSE dating_profiles.dob_set_at END,
        -- The single 48h correction, LOGGED: a differing dob inside the window stamps the log.
        dob_corrected_at = CASE WHEN ($4::text)::date IS NOT NULL AND dating_profiles.dob IS NOT NULL
                                     AND ($4::text)::date <> dating_profiles.dob
                                THEN now() ELSE dating_profiles.dob_corrected_at END,
        gender = COALESCE($5, dating_profiles.gender),
        interested_in = COALESCE($6::text[], dating_profiles.interested_in),
        bio = COALESCE($7, dating_profiles.bio),
        photos = COALESCE(($8::text[])::uuid[], dating_profiles.photos),
        latitude = COALESCE($9, dating_profiles.latitude),
        longitude = COALESCE($10, dating_profiles.longitude),
        location_name = COALESCE($11, dating_profiles.location_name),
        min_age = COALESCE($12, dating_profiles.min_age),
        max_age = COALESCE($13, dating_profiles.max_age),
        max_distance_km = COALESCE($14, dating_profiles.max_distance_km),
        pref_genders = COALESCE($15::text[], dating_profiles.pref_genders),
        last_active_at = now(),
        updated_at = now()
      """,
      [
        user_id,
        app_id,
        updates.enabled,
        updates.dob,
        updates.gender,
        updates.interested_in,
        updates.bio,
        updates.photos,
        location && location.lat,
        location && location.lng,
        location && location.name,
        updates.prefs && prefs[:min_age],
        updates.prefs && prefs[:max_age],
        updates.prefs && prefs[:max_distance_km],
        updates.prefs && prefs[:genders]
      ]
    )
  end

  defp touch_activity(user_id) do
    Repo.query!(
      "UPDATE dating_profiles SET last_active_at = now() WHERE user_id = $1::text::uuid",
      [user_id]
    )
  end

  defp lock_pair(app_id, user_a, user_b) do
    low = min(user_a, user_b)
    high = max(user_a, user_b)

    Repo.query!(
      "SELECT pg_advisory_xact_lock(hashtextextended('dating:' || $1 || ':' || $2 || ':' || $3, 0))",
      [app_id, low, high]
    )
  end

  defp match_of_pair(app_id, user_a, user_b) do
    %{rows: rows} =
      Repo.query!(
        "SELECT id::text, conversation_id::text FROM dating_matches " <>
          "WHERE app_id = $1::text::uuid " <>
          "AND user_low_id = LEAST($2::text::uuid, $3::text::uuid) " <>
          "AND user_high_id = GREATEST($2::text::uuid, $3::text::uuid)",
        [app_id, user_a, user_b]
      )

    case rows do
      [[id, conversation_id]] -> %{match_id: id, conversation_id: conversation_id}
      [] -> nil
    end
  end

  defp reverse_like?(app_id, user_id, target_id) do
    %{rows: [[reverse]]} =
      Repo.query!(
        "SELECT EXISTS (SELECT 1 FROM dating_swipes WHERE app_id = $1::text::uuid " <>
          "AND swiper_id = $2::text::uuid AND target_id = $3::text::uuid AND action = 'like')",
        [app_id, target_id, user_id]
      )

    reverse
  end

  defp upsert_swipe(app_id, swiper, target, action) do
    Repo.query!(
      "INSERT INTO dating_swipes (app_id, swiper_id, target_id, action) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3::text::uuid, $4) " <>
        "ON CONFLICT (app_id, swiper_id, target_id) " <>
        "DO UPDATE SET action = EXCLUDED.action, updated_at = now()",
      [app_id, swiper, target, action]
    )
  end

  defp delete_pair_swipes(app_id, user_a, user_b) do
    Repo.query!(
      "DELETE FROM dating_swipes WHERE app_id = $1::text::uuid AND " <>
        "((swiper_id = $2::text::uuid AND target_id = $3::text::uuid) OR " <>
        "(swiper_id = $3::text::uuid AND target_id = $2::text::uuid))",
      [app_id, user_a, user_b]
    )
  end

  # -- field validators --

  defp opt_bool(attrs, key, atom_key) do
    value =
      case Map.fetch(attrs, key) do
        {:ok, found} -> found
        :error -> Map.get(attrs, atom_key)
      end

    case value do
      nil -> {:ok, nil}
      boolean when is_boolean(boolean) -> {:ok, boolean}
      _ -> {:error, :dating_invalid}
    end
  end

  defp opt_dob(attrs) do
    case get(attrs, "dob") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        case Date.from_iso8601(value) do
          {:ok, date} -> {:ok, Date.to_iso8601(date)}
          _ -> {:error, :dating_invalid}
        end

      _ ->
        {:error, :dating_invalid}
    end
  end

  defp opt_gender(attrs) do
    case get(attrs, "gender") do
      nil -> {:ok, nil}
      value when value in @genders -> {:ok, value}
      _ -> {:error, :dating_invalid}
    end
  end

  defp opt_genders_list(attrs, key, min) do
    case get(attrs, key) do
      nil ->
        {:ok, nil}

      list when is_list(list) ->
        if length(list) >= min and list == Enum.uniq(list) and Enum.all?(list, &(&1 in @genders)),
          do: {:ok, list},
          else: {:error, :dating_invalid}

      _ ->
        {:error, :dating_invalid}
    end
  end

  defp opt_bio(attrs) do
    case get(attrs, "bio") do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, String.slice(value, 0, @bio_max)}
      _ -> {:error, :dating_invalid}
    end
  end

  defp opt_photos(attrs) do
    case get(attrs, "photos") do
      nil ->
        {:ok, nil}

      list when is_list(list) and length(list) <= @max_photos ->
        if Enum.all?(list, &(is_binary(&1) and match?({:ok, _}, Ecto.UUID.cast(&1)))),
          do: {:ok, list},
          else: {:error, :dating_invalid}

      _ ->
        {:error, :dating_invalid}
    end
  end

  defp opt_location(attrs) do
    case get(attrs, "location") do
      nil ->
        {:ok, nil}

      %{} = location ->
        lat = num(Map.get(location, "lat") || Map.get(location, :lat))
        lng = num(Map.get(location, "lng") || Map.get(location, :lng))
        name = Map.get(location, "name") || Map.get(location, :name)

        if is_float(lat) and lat >= -90.0 and lat <= 90.0 and
             is_float(lng) and lng >= -180.0 and lng <= 180.0 and
             is_binary(name) and name != "" and String.length(name) <= 80 do
          {:ok, %{lat: lat, lng: lng, name: name}}
        else
          {:error, :dating_invalid}
        end

      _ ->
        {:error, :dating_invalid}
    end
  end

  defp opt_prefs(attrs) do
    case get(attrs, "prefs") do
      nil ->
        {:ok, nil}

      %{} = prefs ->
        min_age = Map.get(prefs, "min_age")
        max_age = Map.get(prefs, "max_age")
        max_distance = Map.get(prefs, "max_distance_km")
        genders = Map.get(prefs, "genders")

        cond do
          min_age != nil and (not is_integer(min_age) or min_age < 18) ->
            {:error, :dating_invalid}

          max_age != nil and (not is_integer(max_age) or max_age > 100 or max_age < 18) ->
            {:error, :dating_invalid}

          max_distance != nil and
              (not is_integer(max_distance) or max_distance < 1 or max_distance > 500) ->
            {:error, :dating_invalid}

          genders != nil and
              not (is_list(genders) and Enum.all?(genders, &(&1 in @genders))) ->
            {:error, :dating_invalid}

          true ->
            {:ok,
             %{
               min_age: min_age,
               max_age: max_age,
               max_distance_km: max_distance,
               genders: genders
             }}
        end

      _ ->
        {:error, :dating_invalid}
    end
  end

  defp action_of(attrs) do
    case get(attrs, "action") do
      value when value in ["like", "pass"] -> {:ok, value}
      _ -> {:error, :dating_invalid}
    end
  end

  defp not_self(id, id), do: {:error, :dating_self_swipe}
  defp not_self(_, _), do: :ok

  defp limit_of(attrs, default) do
    case get(attrs, "limit") do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp cursor_of(attrs) do
    case get(attrs, "cursor") do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        with {:ok, decoded} <- Base.url_decode64(value, padding: false),
             [ts, id] <- String.split(decoded, "|", parts: 2),
             {:ok, _} <- Ecto.UUID.cast(id) do
          {:ok, {ts, id}}
        else
          _ -> {:error, :dating_invalid}
        end

      _ ->
        {:error, :dating_invalid}
    end
  end

  # Rows carry [.. 6 card cols .., order_ts, order_id | _]; the cursor points at the LAST row.
  defp next_cursor(rows) when length(rows) < @page_limit, do: nil

  defp next_cursor(rows) do
    [ts, id | _] = rows |> List.last() |> Enum.drop(6)
    Base.url_encode64(iso(ts) <> "|" <> id, padding: false)
  end

  defp num(value) when is_integer(value), do: value * 1.0
  defp num(value) when is_float(value), do: value
  defp num(_), do: nil

  defp required(attrs, key) do
    case get(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :dating_invalid}
    end
  end

  defp get(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_atom(key))
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  defp iso(value), do: to_string(value)
end

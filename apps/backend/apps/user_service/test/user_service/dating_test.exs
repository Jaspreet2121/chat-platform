defmodule UserService.DatingTest do
  @moduledoc """
  Dating (105) on real SQL: the enable-gate matrix (every missing field; the under-18 HARD refusal
  including the birthday-today boundary; min_age<18), the single 48h dob correction, the deck's
  mutual-filter matrix (gender/interest both ways, age both ways, min-of-both distance, my-swipe
  hides / their-pass doesn't, match/disabled/blocked hide — blocks at store level), the card shape
  (rounded integer km, NEVER coordinates — locked by exact key set), swipe transitions, the match
  transaction (reverse like → match; idempotent; the raced-loser branch of create_match proven
  directly, the allocate_twin precedent), likes semantics (my pass hides forever), unmatch (swipes
  reset, conversation kept), and the block-hook pair unmatch.
  """
  use UserService.DataCase, async: false

  alias UserService.Dating

  @app_id "00000000-0000-0000-0000-000000000001"
  # Delhi-ish; ~0.045 lat degrees ≈ 5 km.
  @lat 28.6139
  @lng 77.2090

  defp user!(display_name \\ "Test User") do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @app_id, "+1#{System.unique_integer([:positive])}"]
    )

    Repo.query!(
      "INSERT INTO user_profiles (user_id, display_name, app_id, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, $3::text::uuid, now(), now())",
      [id, display_name, @app_id]
    )

    id
  end

  defp media!(owner_id) do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO media_assets (id, owner_user_id, app_id, purpose, storage_provider, bucket, " <>
        "object_key, mime_type, size_bytes, status) VALUES ($1::text::uuid, $2::text::uuid, " <>
        "$3::text::uuid, 'message', 'minio', 'chat-media', $4, 'image/jpeg', 100, 'ready')",
      [id, owner_id, @app_id, "dating/#{id}.jpg"]
    )

    id
  end

  defp dob_years_ago(years), do: Date.utc_today() |> shift_years(-years) |> Date.to_iso8601()

  defp shift_years(%Date{} = date, delta) do
    target_year = date.year + delta
    # Feb 29 → Feb 28 in a non-leap target year.
    case Date.new(target_year, date.month, date.day) do
      {:ok, shifted} -> shifted
      {:error, _} -> Date.new!(target_year, date.month, date.day - 1)
    end
  end

  defp valid_attrs(user_id, overrides \\ %{}) do
    Map.merge(
      %{
        "user_id" => user_id,
        "app_id" => @app_id,
        "enabled" => true,
        "dob" => dob_years_ago(25),
        "gender" => "woman",
        "interested_in" => ["man"],
        "photos" => [media!(user_id), media!(user_id)],
        "location" => %{"lat" => @lat, "lng" => @lng, "name" => "Delhi"},
        "intention" => "open",
        "bio" => "hello"
      },
      overrides
    )
  end

  defp enable!(user_id, overrides \\ %{}) do
    {:ok, profile} = Dating.update_profile(valid_attrs(user_id, overrides))
    assert profile.enabled == true
    profile
  end

  defp deck_ids(user_id) do
    {:ok, %{cards: cards}} = Dating.deck(%{"user_id" => user_id, "app_id" => @app_id})
    Enum.map(cards, & &1.user_id)
  end

  defp swipe(user_id, target_id, action) do
    Dating.swipe(%{
      "user_id" => user_id,
      "app_id" => @app_id,
      "target_id" => target_id,
      "action" => action
    })
  end

  defp likes_ids(user_id) do
    {:ok, %{cards: cards}} = Dating.likes(%{"user_id" => user_id, "app_id" => @app_id})
    Enum.map(cards, & &1.user_id)
  end

  defp block!(blocker, blocked) do
    Repo.query!(
      "INSERT INTO user_blocks (blocker_user_id, blocked_user_id) " <>
        "VALUES ($1::text::uuid, $2::text::uuid)",
      [blocker, blocked]
    )
  end

  @tag :postgres_integration
  test "ENABLE GATE: every missing field refuses; under-18 hard-refuses incl. the boundary; min_age<18 invalid" do
    me = user!()

    for missing <- ["dob", "gender", "interested_in", "location", "intention"] do
      assert {:error, :dating_profile_incomplete} =
               Dating.update_profile(valid_attrs(me, %{missing => nil})),
             "expected incomplete without #{missing}"
    end

    # One photo is not enough; a foreign photo is refused outright.
    assert {:error, :dating_profile_incomplete} =
             Dating.update_profile(valid_attrs(me, %{"photos" => [media!(me)]}))

    stranger = user!()

    assert {:error, :dating_photo_not_owned} =
             Dating.update_profile(valid_attrs(me, %{"photos" => [media!(me), media!(stranger)]}))

    # UNDER-18, hard: 17 refused; 18th birthday TODAY is exactly 18 → allowed; tomorrow-18 refused.
    assert {:error, :dating_underage} =
             Dating.update_profile(valid_attrs(me, %{"dob" => dob_years_ago(17)}))

    eighteen_tomorrow = Date.utc_today() |> shift_years(-18) |> Date.add(1) |> Date.to_iso8601()

    assert {:error, :dating_underage} =
             Dating.update_profile(valid_attrs(me, %{"dob" => eighteen_tomorrow}))

    assert {:ok, %{enabled: true, age: 18}} =
             Dating.update_profile(valid_attrs(me, %{"dob" => dob_years_ago(18)}))

    # min_age below 18 is invalid at validation.
    assert {:error, :dating_invalid} =
             Dating.update_profile(%{
               "user_id" => me,
               "app_id" => @app_id,
               "prefs" => %{"min_age" => 17}
             })

    # Disable: one flag; data retained.
    assert {:ok, %{enabled: false, gender: "woman"}} =
             Dating.update_profile(%{"user_id" => me, "app_id" => @app_id, "enabled" => false})
  end

  @tag :postgres_integration
  test "DOB: immutable except ONE correction within 48h (logged); outside window locked" do
    me = user!()
    enable!(me, %{"dob" => dob_years_ago(25)})

    # The single correction, inside the window — logged.
    assert {:ok, corrected} =
             Dating.update_profile(%{
               "user_id" => me,
               "app_id" => @app_id,
               "dob" => dob_years_ago(26)
             })

    assert corrected.dob_corrected_at != nil

    # A second change is locked forever.
    assert {:error, :dating_dob_locked} =
             Dating.update_profile(%{
               "user_id" => me,
               "app_id" => @app_id,
               "dob" => dob_years_ago(27)
             })

    # Outside the 48h window (never corrected): locked too.
    other = user!()
    enable!(other, %{"dob" => dob_years_ago(30)})

    Repo.query!(
      "UPDATE dating_profiles SET dob_set_at = now() - interval '49 hours' WHERE user_id = $1::text::uuid",
      [other]
    )

    assert {:error, :dating_dob_locked} =
             Dating.update_profile(%{
               "user_id" => other,
               "app_id" => @app_id,
               "dob" => dob_years_ago(31)
             })

    # Re-sending the SAME dob is always fine (idempotent, not a correction).
    assert {:ok, _} =
             Dating.update_profile(%{
               "user_id" => other,
               "app_id" => @app_id,
               "dob" => dob_years_ago(30)
             })
  end

  @tag :postgres_integration
  test "DECK: the mutual-filter matrix, min-of-both distance, and the locked card shape" do
    # A (woman, into men) and B (man, into women) — compatible base pair ~5km apart.
    a = user!("Asha Sharma")
    b = user!("Bharat Kumar")
    enable!(a)

    enable!(b, %{
      "gender" => "man",
      "interested_in" => ["woman"],
      "location" => %{"lat" => @lat + 0.045, "lng" => @lng, "name" => "Delhi North"}
    })

    assert deck_ids(a) == [b]
    assert deck_ids(b) == [a]

    # CARD SHAPE LOCKED: rounded integer km, first name only, and NEVER coordinates.
    {:ok, %{cards: [card]}} = Dating.deck(%{"user_id" => a, "app_id" => @app_id})

    assert Map.keys(card) |> Enum.sort() == [
             :age,
             :bio,
             :display_name,
             :distance_km,
             :intention,
             :photos,
             :shared_turn_ons,
             :turn_ons,
             :user_id
           ]

    assert card.display_name == "Bharat"
    assert is_integer(card.distance_km) and card.distance_km == 5
    assert card.age == 25

    # GENDER/INTEREST is mutual: B narrows to men → the pair disappears BOTH ways.
    {:ok, _} =
      Dating.update_profile(%{"user_id" => b, "app_id" => @app_id, "interested_in" => ["man"]})

    assert deck_ids(a) == []
    assert deck_ids(b) == []

    {:ok, _} =
      Dating.update_profile(%{"user_id" => b, "app_id" => @app_id, "interested_in" => ["woman"]})

    # AGE fits BOTH ways: B demands 30+ (A is 25) → hidden both directions.
    {:ok, _} =
      Dating.update_profile(%{"user_id" => b, "app_id" => @app_id, "prefs" => %{"min_age" => 30}})

    assert deck_ids(a) == []
    assert deck_ids(b) == []

    {:ok, _} =
      Dating.update_profile(%{"user_id" => b, "app_id" => @app_id, "prefs" => %{"min_age" => 18}})

    # DISTANCE is min-of-both: B caps at 1 km (pair is ~5 km) → hidden both ways.
    {:ok, _} =
      Dating.update_profile(%{
        "user_id" => b,
        "app_id" => @app_id,
        "prefs" => %{"max_distance_km" => 1}
      })

    assert deck_ids(a) == []
    assert deck_ids(b) == []

    {:ok, _} =
      Dating.update_profile(%{
        "user_id" => b,
        "app_id" => @app_id,
        "prefs" => %{"max_distance_km" => 100}
      })

    # MY swipe hides them from ME; THEIR pass on me does NOT hide me from them... or them from me.
    assert {:ok, %{matched: false}} = swipe(b, a, "pass")
    assert deck_ids(b) == [], "B swiped: A must leave B's deck"
    assert deck_ids(a) == [b], "B's pass must NOT hide B from A"

    # DISABLED hides instantly.
    {:ok, _} = Dating.update_profile(%{"user_id" => b, "app_id" => @app_id, "enabled" => false})
    assert deck_ids(a) == []
    {:ok, _} = Dating.update_profile(%{"user_id" => b, "app_id" => @app_id, "enabled" => true})

    # BLOCKED, either direction, at the STORE (no gateway anywhere in this suite).
    block!(b, a)
    assert deck_ids(a) == []
    Repo.query!("DELETE FROM user_blocks WHERE blocker_user_id = $1::text::uuid", [b])

    # MATCH hides both ways. (B upgrades the earlier pass to a like — pass→like is allowed — and
    # then A's like completes the match.)
    assert {:ok, %{matched: false}} = swipe(b, a, "like")
    assert {:ok, %{matched: true}} = swipe(a, b, "like")
    assert deck_ids(a) == []
    assert deck_ids(b) == []
  end

  @tag :postgres_integration
  test "SWIPES + MATCH: transitions, the match transaction, idempotence, and the raced-loser branch" do
    a = user!()
    b = user!()
    enable!(a)
    enable!(b, %{"gender" => "man", "interested_in" => ["woman"]})

    # Self-swipe refused.
    assert {:error, :dating_self_swipe} = swipe(a, a, "like")

    # pass → like is a plain update.
    assert {:ok, %{matched: false}} = swipe(a, b, "pass")
    assert {:ok, %{matched: false}} = swipe(a, b, "like")

    # like → pass allowed while unmatched.
    assert {:ok, %{matched: false}} = swipe(a, b, "pass")
    assert {:ok, %{matched: false}} = swipe(a, b, "like")

    # Reverse like completes the MATCH in the swipe transaction.
    assert {:ok, %{matched: true, match_id: match_id}} = swipe(b, a, "like")

    %{rows: [[match_count]]} = Repo.query!("SELECT count(*)::int FROM dating_matches", [])
    assert match_count == 1

    # Idempotent: liking again re-reports the same match; like→pass now refuses (matched).
    assert {:ok, %{matched: true, match_id: ^match_id}} = swipe(b, a, "like")
    assert {:error, :dating_matched} = swipe(a, b, "pass")

    # RACED LOSER (the allocate_twin precedent): create_match on an existing pair takes the
    # ON-CONFLICT-zero-rows path and the guaranteed re-select returns the SAME match.
    assert %{match_id: ^match_id} = Dating.create_match(@app_id, a, b)

    # attach: stamps only while NULL.
    conversation = Ecto.UUID.generate()

    assert {:ok, %{attached: true}} =
             Dating.attach_match_conversation(%{
               "match_id" => match_id,
               "conversation_id" => conversation
             })

    assert {:ok, _} =
             Dating.attach_match_conversation(%{
               "match_id" => match_id,
               "conversation_id" => Ecto.UUID.generate()
             })

    %{rows: [[stored]]} =
      Repo.query!("SELECT conversation_id::text FROM dating_matches WHERE id = $1::text::uuid", [
        match_id
      ])

    assert stored == conversation
  end

  @tag :postgres_integration
  test "LIKES YOU: reverse likes minus my swipes; my pass hides FOREVER; disabled/blocked likers hidden" do
    me = user!()
    liker = user!("Liker One")
    passed_liker = user!()
    disabled_liker = user!()
    enable!(me)

    for {u, _} <- [{liker, 1}, {passed_liker, 2}, {disabled_liker, 3}] do
      enable!(u, %{"gender" => "man", "interested_in" => ["woman"]})
      assert {:ok, %{matched: false}} = swipe(u, me, "like")
    end

    assert Enum.sort(likes_ids(me)) == Enum.sort([liker, passed_liker, disabled_liker])

    # My PASS hides that liker from my list forever (their like row remains — never notified).
    assert {:ok, %{matched: false}} = swipe(me, passed_liker, "pass")
    refute passed_liker in likes_ids(me)

    %{rows: [[their_like]]} =
      Repo.query!(
        "SELECT count(*)::int FROM dating_swipes WHERE swiper_id = $1::text::uuid AND action = 'like'",
        [passed_liker]
      )

    assert their_like == 1

    # A liker who disables disappears; blocked pairs too (store level).
    {:ok, _} =
      Dating.update_profile(%{
        "user_id" => disabled_liker,
        "app_id" => @app_id,
        "enabled" => false
      })

    refute disabled_liker in likes_ids(me)

    block!(liker, me)
    assert likes_ids(me) == []
  end

  @tag :postgres_integration
  test "UNMATCH: match row gone, BOTH swipes reset to none, conversation kept; block-hook pair variant" do
    a = user!()
    b = user!()
    enable!(a)
    enable!(b, %{"gender" => "man", "interested_in" => ["woman"]})

    assert {:ok, %{matched: false}} = swipe(a, b, "like")
    assert {:ok, %{matched: true, match_id: match_id}} = swipe(b, a, "like")

    conversation = Ecto.UUID.generate()

    {:ok, _} =
      Dating.attach_match_conversation(%{
        "match_id" => match_id,
        "conversation_id" => conversation
      })

    # A stranger cannot unmatch it.
    stranger = user!()

    assert {:error, :dating_match_not_found} =
             Dating.unmatch(%{"user_id" => stranger, "app_id" => @app_id, "match_id" => match_id})

    assert {:ok, %{unmatched: true, peer_user_id: ^b}} =
             Dating.unmatch(%{"user_id" => a, "app_id" => @app_id, "match_id" => match_id})

    %{rows: [[matches]]} = Repo.query!("SELECT count(*)::int FROM dating_matches", [])
    %{rows: [[swipes]]} = Repo.query!("SELECT count(*)::int FROM dating_swipes", [])
    assert matches == 0
    # BOTH swipe rows reset to none — neither reappears in the other's likes.
    assert swipes == 0
    assert likes_ids(a) == []
    assert likes_ids(b) == []

    # The conversation row is NOT ours to delete (recorded decision) — nothing here touched it;
    # both may resurface in each other's decks (no swipe rows).
    assert deck_ids(a) == [b]

    # BLOCK HOOK variant: re-match, then unmatch_pair (what the gateway calls after a block).
    assert {:ok, %{matched: false}} = swipe(a, b, "like")
    assert {:ok, %{matched: true, match_id: match2}} = swipe(b, a, "like")

    assert {:ok, %{unmatched: true, match_id: ^match2}} =
             Dating.unmatch_pair(%{"user_id" => a, "app_id" => @app_id, "peer_user_id" => b})

    assert {:ok, %{unmatched: false, match_id: nil}} =
             Dating.unmatch_pair(%{"user_id" => a, "app_id" => @app_id, "peer_user_id" => b})
  end

  # ---- v2 (106): intention + turn-ons -----------------------------------------------------------

  defp patch!(user_id, fields) do
    Dating.update_profile(Map.merge(%{"user_id" => user_id, "app_id" => @app_id}, fields))
  end

  defp pair!(overrides_a \\ %{}, overrides_b \\ %{}) do
    a = user!("Asha Sharma")
    b = user!("Bharat Kumar")
    enable!(a, overrides_a)

    enable!(
      b,
      Map.merge(
        %{
          "gender" => "man",
          "interested_in" => ["woman"],
          "location" => %{"lat" => @lat + 0.001, "lng" => @lng, "name" => "Delhi"}
        },
        overrides_b
      )
    )

    {a, b}
  end

  @tag :postgres_integration
  test "TAGS (106): unknown key 422, >15 refused, dedupe preserves order as sent" do
    me = user!()

    assert {:error, :dating_invalid_tag} = patch!(me, %{"turn_ons" => ["kissing", "nonsense"]})
    assert {:error, :dating_invalid_tag} = patch!(me, %{"intention" => "married"})

    sixteen =
      SharedInfra.DatingTags.turn_on_keys() |> Enum.take(16)

    assert {:error, :dating_invalid} = patch!(me, %{"turn_ons" => sixteen})

    # Dedupe keeps FIRST occurrence; order preserved as sent.
    assert {:ok, saved} =
             patch!(me, %{"turn_ons" => ["chai_dates", "kissing", "chai_dates", "deep_talks"]})

    assert saved.turn_ons == ["chai_dates", "kissing", "deep_talks"]

    # Prefs: unknown intention key in the filter is the same 422.
    assert {:error, :dating_invalid_tag} = patch!(me, %{"prefs" => %{"intentions" => ["nope"]}})
  end

  @tag :postgres_integration
  test "GRANDFATHER (106): a 105-era enabled row backfills to figuring; a disabled row must state one to enable" do
    # A row enabled BEFORE 106 (intention NULL) — the migration's backfill statement stamps it.
    legacy = user!()

    Repo.query!(
      "INSERT INTO dating_profiles (user_id, app_id, enabled, dob, gender, interested_in, photos, " <>
        "latitude, longitude, location_name) VALUES ($1::text::uuid, $2::text::uuid, true, " <>
        "'1999-01-01', 'woman', '{man}', ('{' || gen_random_uuid() || ',' || gen_random_uuid() || '}')::uuid[], " <>
        "28.6, 77.2, 'Delhi')",
      [legacy, @app_id]
    )

    Repo.query!(
      "UPDATE dating_profiles SET intention = 'figuring' WHERE enabled AND intention IS NULL",
      []
    )

    assert {:ok, %{intention: "figuring", enabled: true}} =
             Dating.get_profile(%{"user_id" => legacy})

    # Their next ordinary save keeps working (intention already present in the merged state).
    assert {:ok, %{enabled: true}} = patch!(legacy, %{"bio" => "still here"})

    # A DISABLED profile with no intention cannot enable without stating one...
    fresh = user!()

    incomplete =
      valid_attrs(fresh) |> Map.delete("intention")

    assert {:error, :dating_profile_incomplete} = Dating.update_profile(incomplete)

    # ...and can with one.
    assert {:ok, %{enabled: true, intention: "serious"}} =
             Dating.update_profile(Map.put(incomplete, "intention", "serious"))
  end

  @tag :postgres_integration
  test "CARDS (106): shared_turn_ons is the intersection in the TARGET's order; empty when disjoint" do
    {a, b} =
      pair!(
        %{"turn_ons" => ["kissing", "deep_talks", "chai_dates"]},
        %{"turn_ons" => ["long_drives", "chai_dates", "gaming", "kissing"]}
      )

    {:ok, %{cards: [card]}} = Dating.deck(%{"user_id" => a, "app_id" => @app_id})
    assert card.user_id == b
    assert card.intention == "open"
    assert card.turn_ons == ["long_drives", "chai_dates", "gaming", "kissing"]
    # Intersection with MY tags, in THE TARGET'S order (chai_dates before kissing — B's order).
    assert card.shared_turn_ons == ["chai_dates", "kissing"]

    # Disjoint sets → empty, never nil.
    {:ok, _} = patch!(a, %{"turn_ons" => ["yoga"]})
    {:ok, %{cards: [card2]}} = Dating.deck(%{"user_id" => a, "app_id" => @app_id})
    assert card2.shared_turn_ons == []

    # The v2 card adds EXACTLY three keys — nothing else new leaks.
    assert Map.keys(card) |> Enum.sort() ==
             [
               :age,
               :bio,
               :display_name,
               :distance_km,
               :intention,
               :photos,
               :shared_turn_ons,
               :turn_ons,
               :user_id
             ]

    # Likes cards carry the same trio.
    assert {:ok, %{matched: false}} = swipe(b, a, "like")
    {:ok, %{cards: [like_card]}} = Dating.likes(%{"user_id" => a, "app_id" => @app_id})
    assert like_card.user_id == b
    assert like_card.turn_ons == ["long_drives", "chai_dates", "gaming", "kissing"]
    assert like_card.shared_turn_ons == []
  end

  @tag :postgres_integration
  test "DECK ORDERING (106): overlap count desc, then recency, then random — locked with a tiebreak" do
    viewer = user!("Viewer")
    enable!(viewer, %{"turn_ons" => ["kissing", "chai_dates", "deep_talks"]})

    make = fn name, turn_ons, active_shift ->
      candidate = user!(name)

      enable!(candidate, %{
        "gender" => "man",
        "interested_in" => ["woman"],
        "location" => %{"lat" => @lat + 0.001, "lng" => @lng, "name" => "Delhi"},
        "turn_ons" => turn_ons
      })

      Repo.query!(
        "UPDATE dating_profiles SET last_active_at = now() - make_interval(secs => $2) " <>
          "WHERE user_id = $1::text::uuid",
        [candidate, active_shift]
      )

      candidate
    end

    two_shared = make.("Two Shared", ["kissing", "chai_dates"], 3600)
    one_shared_fresh = make.("One Fresh", ["kissing"], 60)
    one_shared_stale = make.("One Stale", ["kissing", "gaming"], 7200)
    zero_shared = make.("Zero", ["yoga"], 10)

    {:ok, %{cards: cards}} = Dating.deck(%{"user_id" => viewer, "app_id" => @app_id})

    # Overlap 2 first; the two overlap-1 candidates by recency (fresh before stale); zero last —
    # even though zero_shared is the most recently active overall.
    assert Enum.map(cards, & &1.user_id) == [
             two_shared,
             one_shared_fresh,
             one_shared_stale,
             zero_shared
           ]

    # REQUIRE_SHARED_TURN_ON: the zero-overlap candidate drops; the rest stay.
    {:ok, _} = patch!(viewer, %{"prefs" => %{"require_shared_turn_on" => true}})
    {:ok, %{cards: filtered}} = Dating.deck(%{"user_id" => viewer, "app_id" => @app_id})
    assert Enum.map(filtered, & &1.user_id) == [two_shared, one_shared_fresh, one_shared_stale]

    # And off again (the boolean false must STICK — the falsy trap).
    {:ok, saved} = patch!(viewer, %{"prefs" => %{"require_shared_turn_on" => false}})
    assert saved.pref_require_shared_turn_on == false
    {:ok, %{cards: back}} = Dating.deck(%{"user_id" => viewer, "app_id" => @app_id})
    assert length(back) == 4
  end

  @tag :postgres_integration
  test "INTENTION FILTER (106): my pref narrows MY deck only — the candidate's pref never hides them from me" do
    {a, b} = pair!(%{"intention" => "serious"}, %{"intention" => "casual"})

    # My pref filters my deck: A wants serious-only → B (casual) leaves A's deck.
    {:ok, _} = patch!(a, %{"prefs" => %{"intentions" => ["serious"]}})
    {:ok, %{cards: a_deck}} = Dating.deck(%{"user_id" => a, "app_id" => @app_id})
    assert a_deck == []

    # ASYMMETRY: A's pref does NOT hide A from B's deck (their pref governs their deck alone) —
    # and B's own empty pref admits everyone.
    {:ok, %{cards: b_deck}} = Dating.deck(%{"user_id" => b, "app_id" => @app_id})
    assert Enum.map(b_deck, & &1.user_id) == [a]

    # B's pref, in turn, narrows only B's deck.
    {:ok, _} = patch!(b, %{"prefs" => %{"intentions" => ["casual", "open"]}})
    {:ok, %{cards: b_deck2}} = Dating.deck(%{"user_id" => b, "app_id" => @app_id})
    assert b_deck2 == []

    # Widening A's pref brings B back — B's pref still irrelevant to A's deck.
    {:ok, _} = patch!(a, %{"prefs" => %{"intentions" => []}})
    {:ok, %{cards: a_deck2}} = Dating.deck(%{"user_id" => a, "app_id" => @app_id})
    assert Enum.map(a_deck2, & &1.user_id) == [b]
  end
end

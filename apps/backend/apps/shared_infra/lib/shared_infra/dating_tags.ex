defmodule SharedInfra.DatingTags do
  @moduledoc """
  The dating tag CATALOG (106) — intentions + turn-ons, a code module like the builtin slash
  commands (no DB table; the list changes only with a deploy, so the catalog endpoint serves it
  with a strong ETag). KEYS ARE THE WIRE CONTRACT: clients store and send keys; labels are
  presentation and may localize later. Lives in shared_infra because BOTH sides need it — the
  gateway serves the catalog, the user service validates stored keys against it.
  """

  @intentions [
    %{key: "serious", label: "Serious relationship"},
    %{key: "casual", label: "Something casual"},
    %{key: "open", label: "Open to either"},
    %{key: "friends", label: "New friends"},
    %{key: "figuring", label: "Still figuring it out"}
  ]

  @turn_ons [
    # romance
    %{key: "kissing", label: "Kissing", category: "romance"},
    %{key: "cuddling", label: "Cuddling", category: "romance"},
    %{key: "massages", label: "Massages", category: "romance"},
    %{key: "slow_dancing", label: "Slow dancing", category: "romance"},
    %{key: "eye_contact", label: "Eye contact", category: "romance"},
    %{key: "flirty_banter", label: "Flirty banter", category: "romance"},
    %{key: "playful_teasing", label: "Playful teasing", category: "romance"},
    %{key: "late_night_calls", label: "Late-night calls", category: "romance"},
    %{key: "voice_notes", label: "Voice notes", category: "romance"},
    %{key: "holding_hands", label: "Holding hands", category: "romance"},
    %{key: "old_school_romance", label: "Old-school romance", category: "romance"},
    %{key: "compliments", label: "Compliments", category: "romance"},
    %{key: "candlelit_dinners", label: "Candlelit dinners", category: "romance"},
    %{key: "whispering", label: "Whispering", category: "romance"},
    %{key: "love_letters", label: "Love letters", category: "romance"},
    # vibes
    %{key: "deep_talks", label: "Deep talks", category: "vibes"},
    %{key: "good_humor", label: "Good humor", category: "vibes"},
    %{key: "ambition", label: "Ambition", category: "vibes"},
    %{key: "bookworm", label: "Bookworm", category: "vibes"},
    %{key: "poetry_shayari", label: "Poetry & shayari", category: "vibes"},
    %{key: "artsy_dates", label: "Artsy dates", category: "vibes"},
    %{key: "been_to_therapy", label: "Been to therapy", category: "vibes"},
    %{key: "feminism", label: "Feminism", category: "vibes"},
    %{key: "live_music", label: "Live music", category: "vibes"},
    %{key: "bollywood_nights", label: "Bollywood nights", category: "vibes"},
    %{key: "chai_dates", label: "Chai dates", category: "vibes"},
    %{key: "coffee_dates", label: "Coffee dates", category: "vibes"},
    %{key: "street_food", label: "Street food hunts", category: "vibes"},
    %{key: "foodie", label: "Foodie", category: "vibes"},
    %{key: "long_drives", label: "Long drives", category: "vibes"},
    %{key: "road_trips", label: "Road trips", category: "vibes"},
    %{key: "mountains", label: "Mountains", category: "vibes"},
    %{key: "beach_person", label: "Beach person", category: "vibes"},
    %{key: "gym_life", label: "Gym life", category: "vibes"},
    %{key: "yoga", label: "Yoga", category: "vibes"},
    %{key: "cricket", label: "Cricket", category: "vibes"},
    %{key: "gaming", label: "Gaming", category: "vibes"},
    %{key: "pet_lover", label: "Pet lover", category: "vibes"},
    %{key: "night_owl", label: "Night owl", category: "vibes"},
    %{key: "early_bird", label: "Early bird", category: "vibes"},
    %{key: "spirituality", label: "Spirituality", category: "vibes"},
    %{key: "travel_stories", label: "Travel stories", category: "vibes"},
    %{key: "dancing", label: "Dancing", category: "vibes"}
  ]

  @intention_keys Enum.map(@intentions, & &1.key)
  @turn_on_keys Enum.map(@turn_ons, & &1.key)

  def intentions, do: @intentions
  def turn_ons, do: @turn_ons
  def intention_keys, do: @intention_keys
  def turn_on_keys, do: @turn_on_keys
  def valid_intention?(key), do: key in @intention_keys
  def valid_turn_on?(key), do: key in @turn_on_keys
end

defmodule MessageService.StatusDurationTest do
  @moduledoc """
  Per-user status DURATION (112).

  Expiry was a fixed 24h written into `status_posts.expires_at` at INSERT and filtered at read. This
  makes the 24 a per-user preference without touching either mechanism, so the tests that matter are
  the ones about WHEN the setting is read:

    * a new post is stamped with the CURRENT setting;
    * a LATER settings change moves nothing already posted — mutation-proven, because making it
      retroactive is the obvious "improvement" someone would reach for, and it would make statuses a
      contact is already viewing vanish out from under them;
    * a user who never set one still gets 24h, byte-identical to before this slice.
  """
  use MessageService.DataCase, async: false

  alias MessageService.Statuses

  setup do
    prev = %{
      persistence: Application.get_env(:message_service, :message_persistence, false),
      sweep: Application.get_env(:message_service, :status_sweep_async)
    }

    Application.put_env(:message_service, :message_persistence, true)
    Application.put_env(:message_service, :status_sweep_async, false)

    on_exit(fn ->
      Application.put_env(:message_service, :message_persistence, prev.persistence)

      if prev.sweep == nil,
        do: Application.delete_env(:message_service, :status_sweep_async),
        else: Application.put_env(:message_service, :status_sweep_async, prev.sweep)
    end)

    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, email, password_hash, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2, 'x', now(), now())",
      [id, "#{id}@test.local"]
    )

    id
  end

  defp post!(owner, body \\ "hello") do
    {:ok, post} =
      Statuses.post_status(%{"owner_user_id" => owner, "kind" => "text", "body" => body})

    post
  end

  # The row's OWN arithmetic, in the database: how many hours the stored expiry sits after the stored
  # creation time. Asserting on this (rather than on wall-clock now()) is what makes it exact.
  defp stored_ttl_hours(status_id) do
    %{rows: [[hours]]} =
      Repo.query!(
        "SELECT EXTRACT(EPOCH FROM (expires_at - created_at)) / 3600 FROM status_posts WHERE id = $1::text::uuid",
        [status_id]
      )

    Decimal.round(hours, 4) |> Decimal.to_float()
  end

  describe "settings round-trip" do
    @tag :postgres_integration
    test "a user who never set one gets the 24h default, plus the allowed list" do
      owner = user!()

      assert {:ok, settings} = Statuses.get_settings(%{"user_id" => owner})
      assert settings.duration_hours == 24
      # Served, not hardcoded client-side — the picker renders from this.
      assert settings.allowed_duration_hours == [6, 12, 24, 48]
    end

    @tag :postgres_integration
    test "setting a duration persists and reads back" do
      owner = user!()

      assert {:ok, saved} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 6})
      assert saved.duration_hours == 6

      assert {:ok, %{duration_hours: 6}} = Statuses.get_settings(%{"user_id" => owner})
    end

    @tag :postgres_integration
    test "every allowed value is accepted; a string form works too (JSON round-trip)" do
      owner = user!()

      for hours <- [6, 12, 24, 48] do
        assert {:ok, %{duration_hours: ^hours}} =
                 Statuses.set_settings(%{"user_id" => owner, "duration_hours" => hours})
      end

      assert {:ok, %{duration_hours: 12}} =
               Statuses.set_settings(%{"user_id" => owner, "duration_hours" => "12"})
    end

    @tag :postgres_integration
    test "anything outside the server-owned enum is refused" do
      owner = user!()

      for bad <- [1, 5, 25, 36, 72, 0, -6, "many", nil, 24.5] do
        assert {:error, :status_invalid_duration} =
                 Statuses.set_settings(%{"user_id" => owner, "duration_hours" => bad}),
               "accepted #{inspect(bad)}"
      end

      # And a refused write leaves the previous value alone.
      assert {:ok, %{duration_hours: 24}} = Statuses.get_settings(%{"user_id" => owner})
    end

    @tag :postgres_integration
    test "duration and audience share ONE row without disturbing each other" do
      owner = user!()

      {:ok, _} = Statuses.set_audience(%{"user_id" => owner, "mode" => "contacts"})
      {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 48})

      # Setting the duration did not reset the audience...
      assert {:ok, %{mode: "contacts"}} = Statuses.get_audience(%{"user_id" => owner})

      # ...and setting the audience does not reset the duration.
      {:ok, _} = Statuses.set_audience(%{"user_id" => owner, "mode" => "only"})
      assert {:ok, %{duration_hours: 48}} = Statuses.get_settings(%{"user_id" => owner})
      assert {:ok, %{mode: "only"}} = Statuses.get_audience(%{"user_id" => owner})
    end
  end

  describe "creation honours the setting" do
    @tag :postgres_integration
    test "a 6h setting stamps the row with a 6h expiry" do
      owner = user!()
      {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 6})

      post = post!(owner)

      # Asserted on the STORED row, not the response — this is the thing that expires it.
      assert stored_ttl_hours(post.status_id) == 6.0
    end

    @tag :postgres_integration
    test "a user who never set one still gets exactly 24h — unchanged from before this slice" do
      owner = user!()
      post = post!(owner)

      assert stored_ttl_hours(post.status_id) == 24.0
    end

    @tag :postgres_integration
    test "each allowed duration produces exactly that expiry" do
      for hours <- [6, 12, 24, 48] do
        owner = user!()
        {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => hours})
        post = post!(owner)

        assert stored_ttl_hours(post.status_id) == hours * 1.0
      end
    end

    @tag :postgres_integration
    test "the setting is per USER — one person's choice does not affect another's posts" do
      short = user!()
      normal = user!()
      {:ok, _} = Statuses.set_settings(%{"user_id" => short, "duration_hours" => 6})

      assert stored_ttl_hours(post!(short).status_id) == 6.0
      assert stored_ttl_hours(post!(normal).status_id) == 24.0
    end
  end

  describe "NEVER retroactive" do
    @tag :postgres_integration
    test "changing the setting later leaves an EXISTING post's expiry untouched" do
      owner = user!()

      # Posted while the setting was 48h.
      {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 48})
      old = post!(owner, "posted at 48h")
      assert stored_ttl_hours(old.status_id) == 48.0

      # Now shorten it. THE MUTATION POINT: make duration retroactive (an UPDATE over status_posts in
      # set_settings, or reading the setting at read-time instead of at INSERT) and this fails.
      {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 6})

      assert stored_ttl_hours(old.status_id) == 48.0,
             "an existing status's expiry moved — viewers would lose a post they are already watching"

      # And only posts made AFTER the change get the new duration.
      assert stored_ttl_hours(post!(owner, "posted at 6h").status_id) == 6.0
    end

    @tag :postgres_integration
    test "lengthening later does not extend an existing post either — the rule is symmetric" do
      owner = user!()
      {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 6})
      old = post!(owner)

      {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 48})

      assert stored_ttl_hours(old.status_id) == 6.0
    end
  end

  describe "read-side filtering is unchanged" do
    @tag :postgres_integration
    test "a 24h post is live and listed exactly as before" do
      owner = user!()
      post = post!(owner)

      assert {:ok, %{posts: posts}} =
               Statuses.list_posts(%{"viewer_user_id" => owner, "owner_user_id" => owner})

      assert Enum.map(posts, & &1.status_id) == [post.status_id]
    end

    @tag :postgres_integration
    test "a SHORT-duration post is live while inside its window" do
      owner = user!()
      {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 6})
      post = post!(owner)

      assert {:ok, %{posts: posts}} =
               Statuses.list_posts(%{"viewer_user_id" => owner, "owner_user_id" => owner})

      assert Enum.map(posts, & &1.status_id) == [post.status_id]
    end

    @tag :postgres_integration
    test "the SAME read filter drops it once its (shorter) window has passed" do
      owner = user!()
      {:ok, _} = Statuses.set_settings(%{"user_id" => owner, "duration_hours" => 6})
      post = post!(owner)

      # Age the row past its 6h window — the read filter is untouched `expires_at > now()`, so this is
      # exactly what a real 6h-old post looks like.
      Repo.query!(
        "UPDATE status_posts SET created_at = now() - interval '7 hours', " <>
          "expires_at = now() - interval '1 hour' WHERE id = $1::text::uuid",
        [post.status_id]
      )

      assert {:ok, %{posts: []}} =
               Statuses.list_posts(%{"viewer_user_id" => owner, "owner_user_id" => owner})
    end
  end

  describe "the shared enum" do
    test "is the single Elixir source, and agrees with what the API serves" do
      assert SharedInfra.StatusDuration.allowed() == [6, 12, 24, 48]
      assert SharedInfra.StatusDuration.default() == 24
      assert SharedInfra.StatusDuration.allowed?(6)
      refute SharedInfra.StatusDuration.allowed?(5)
      refute SharedInfra.StatusDuration.allowed?("6")
    end
  end
end

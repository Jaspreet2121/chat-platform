defmodule UserService.AutoReplyJsonbShapeTest do
  @moduledoc """
  THE STORED SHAPE of the auto-reply blocks, on real SQL — the class of bug every unit test missed
  for two weeks, because a map went in and a map came back out while the COLUMN held something else.

  The old write path ran `Jason.encode!(block)` and bound the resulting STRING to a `$N::jsonb`
  parameter. Postgrex encodes a jsonb parameter with its own JSON encoder, so the text was encoded a
  SECOND time and stored as a jsonb *string*: `jsonb_typeof(away) = 'string'` and
  `away ->> 'enabled'` = NULL. `get_settings/1` decoded that string on the way out, so the API and
  the UI looked perfect — nothing in-process could see it. Only SQL could.

  So these tests assert against the COLUMN, not the round trip:

    * a saved block is a jsonb OBJECT whose keys answer SQL operators (`->>`);
    * a legacy string row is still decoded on read, and logs a warning naming the user;
    * migration 119 unwraps exactly the string columns, leaves objects untouched, and is a no-op on
      a second run — the file itself is executed, not a copy of it;
    * END-TO-END: a rule saved through the context, read back through the CONSUMER's own load path
      (`SharedInfra.UserClient.get_auto_replies/1`), drives `decide/1` to SEND. That is the test
      that would have caught the whole thing.
  """
  use UserService.DataCase, async: false

  import ExUnit.CaptureLog

  alias UserService.AutoReplies

  @tenant_zero "00000000-0000-0000-0000-000000000001"
  @migration Path.join([
               __DIR__,
               "..",
               "..",
               "..",
               "shared_infra",
               "priv",
               "schema",
               "119_auto_reply_settings_unwrap.sql"
             ])

  @away %{"enabled" => true, "mode" => "always", "body" => "Away right now"}
  @greeting %{"enabled" => true, "body" => "Hi there", "resend_after_days" => 7}

  setup do
    prev = Application.get_env(:user_service, :user_profile_persistence, false)
    Application.put_env(:user_service, :user_profile_persistence, true)
    on_exit(fn -> Application.put_env(:user_service, :user_profile_persistence, prev) end)
    :ok
  end

  defp user! do
    id = Ecto.UUID.generate()

    Repo.query!(
      "INSERT INTO users_auth (id, app_id, phone_number, password_hash, status, created_at, updated_at) " <>
        "VALUES ($1::text::uuid, $2::text::uuid, $3, 'x', 'active', now(), now())",
      [id, @tenant_zero, "+1#{System.unique_integer([:positive])}"]
    )

    id
  end

  defp patch(user_id, blocks) do
    AutoReplies.update_settings(
      Map.merge(%{"user_id" => user_id, "app_id" => @tenant_zero}, blocks)
    )
  end

  # Turn an ALREADY-CORRECT row into the pre-fix shape, in place: read the validated blocks back and
  # rewrite them the way the old writer did — Jason.encode! then bind to a `$N::jsonb` parameter.
  # Faithful by construction: the legacy fixture is the very block validation produced, double
  # encoded, so a shape comparison against a fresh row is comparing storage and nothing else.
  defp degrade_to_legacy!(user_id) do
    {away, greeting} = raw_blocks(user_id)

    Repo.query!(
      "UPDATE auto_reply_settings SET away = $2::jsonb, greeting = $3::jsonb " <>
        "WHERE user_id = $1::text::uuid",
      [user_id, Jason.encode!(away), Jason.encode!(greeting)]
    )
  end

  defp legacy_row!(user_id, blocks) do
    assert {:ok, _} = patch(user_id, blocks)
    degrade_to_legacy!(user_id)
  end

  defp column_shape(user_id) do
    %{rows: [row]} =
      Repo.query!(
        """
        SELECT jsonb_typeof(away), jsonb_typeof(greeting),
               away ->> 'enabled', away ->> 'body', greeting ->> 'enabled'
        FROM auto_reply_settings WHERE user_id = $1::text::uuid
        """,
        [user_id]
      )

    [away_type, greeting_type, away_enabled, away_body, greeting_enabled] = row

    %{
      away_type: away_type,
      greeting_type: greeting_type,
      away_enabled: away_enabled,
      away_body: away_body,
      greeting_enabled: greeting_enabled
    }
  end

  defp raw_blocks(user_id) do
    %{rows: [[away, greeting]]} =
      Repo.query!(
        "SELECT away, greeting FROM auto_reply_settings WHERE user_id = $1::text::uuid",
        [user_id]
      )

    {away, greeting}
  end

  # Run the SHIPPED migration file. BEGIN/COMMIT are stripped: the Ecto sandbox already holds this
  # test inside a transaction, and the statements are what we are asserting about.
  defp run_migration! do
    @migration
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "--"))
    |> Enum.join("\n")
    |> String.replace(~r/\b(BEGIN|COMMIT)\s*;/i, "")
    |> String.split(";", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&Repo.query!(&1, []))
  end

  # --- the write path ------------------------------------------------------------------------------

  @tag :postgres_integration
  test "a SAVED block is a jsonb OBJECT whose keys answer SQL operators" do
    user = user!()
    assert {:ok, _} = patch(user, %{"away" => @away, "greeting" => @greeting})

    shape = column_shape(user)

    # THE ASSERTION THE UNIT TESTS COULD NOT MAKE: the column's own type.
    assert shape.away_type == "object",
           "away is stored as #{shape.away_type}, not an object — the block was double-encoded, " <>
             "so every SQL-side read of it (and the engine) sees nothing"

    assert shape.greeting_type == "object"

    # ...and the keys are reachable from SQL, which is what "object" has to mean in practice.
    assert shape.away_enabled == "true"
    assert shape.away_body == "Away right now"
    assert shape.greeting_enabled == "true"

    # Postgrex hands an object column back as a MAP (a legacy string comes back as a binary).
    {away, greeting} = raw_blocks(user)
    assert is_map(away) and is_map(greeting)
    assert away["enabled"] == true
  end

  @tag :postgres_integration
  test "the INSERT default and a partial PATCH agree — no arm can leave a string behind" do
    user = user!()

    # away only: greeting takes the SQL-literal '{}' default (the arm that was always an object).
    assert {:ok, _} = patch(user, %{"away" => @away})
    assert %{away_type: "object", greeting_type: "object"} = column_shape(user)

    # greeting only, on the existing row: away must survive AND stay an object.
    assert {:ok, _} = patch(user, %{"greeting" => @greeting})
    shape = column_shape(user)
    assert shape.away_type == "object"
    assert shape.greeting_type == "object"
    assert shape.away_enabled == "true"
    assert shape.greeting_enabled == "true"
  end

  # --- legacy tolerance ----------------------------------------------------------------------------

  @tag :postgres_integration
  test "a LEGACY double-encoded row is still decoded on read, and WARNS naming the user" do
    user = user!()
    legacy_row!(user, %{"away" => @away, "greeting" => @greeting})

    # The fixture is genuinely the broken shape — otherwise this test proves nothing.
    assert %{away_type: "string", away_enabled: nil} = column_shape(user)

    log =
      capture_log(fn ->
        assert {:ok, settings} = AutoReplies.get_settings(%{"user_id" => user})
        assert settings.away["enabled"] == true
        assert settings.away["body"] == "Away right now"
        assert settings.greeting["enabled"] == true
        assert settings.greeting["resend_after_days"] == 7
      end)

    assert log =~ "LEGACY double-encoded away"
    assert log =~ "LEGACY double-encoded greeting"
    assert log =~ user
  end

  @tag :postgres_integration
  test "the GET shape is IDENTICAL for a legacy row and a freshly written one — key-set pinned" do
    fresh = user!()
    legacy = user!()

    assert {:ok, _} = patch(fresh, %{"away" => @away, "greeting" => @greeting})
    legacy_row!(legacy, %{"away" => @away, "greeting" => @greeting})

    {:ok, from_fresh} = AutoReplies.get_settings(%{"user_id" => fresh})

    {:ok, from_legacy} =
      capture_log_value(fn -> AutoReplies.get_settings(%{"user_id" => legacy}) end)

    # The API contract the clients parse — whole key-sets, both levels.
    assert Map.keys(from_fresh) |> Enum.sort() == [:away, :greeting]
    assert Map.keys(from_legacy) |> Enum.sort() == [:away, :greeting]

    assert from_fresh.away |> Map.keys() |> Enum.sort() ==
             ["audience", "body", "enabled", "except_ids", "mode", "schedule"]

    assert from_fresh.greeting |> Map.keys() |> Enum.sort() ==
             ["audience", "body", "enabled", "except_ids", "resend_after_days"]

    # Byte-identical between the two storage shapes: that is why the UI never revealed the bug.
    assert from_legacy == from_fresh
  end

  defp capture_log_value(fun) do
    result = :erlang.make_ref()
    parent = self()
    _ = capture_log(fn -> send(parent, {result, fun.()}) end)
    receive do: ({^result, value} -> value)
  end

  # --- migration 119 -------------------------------------------------------------------------------

  @tag :postgres_integration
  test "MIGRATION 119 unwraps strings, leaves objects untouched, and a second run changes NOTHING" do
    legacy = user!()
    correct = user!()

    legacy_row!(legacy, %{"away" => @away, "greeting" => @greeting})
    assert {:ok, _} = patch(correct, %{"away" => @away, "greeting" => @greeting})

    assert %{away_type: "string", greeting_type: "string"} = column_shape(legacy)
    assert %{away_type: "object", greeting_type: "object"} = column_shape(correct)

    run_migration!()

    # The legacy row is now a real object with its values intact...
    after_first = column_shape(legacy)
    assert after_first.away_type == "object"
    assert after_first.greeting_type == "object"
    assert after_first.away_enabled == "true"
    assert after_first.away_body == "Away right now"
    assert after_first.greeting_enabled == "true"

    # ...and the already-correct row was not touched.
    assert column_shape(correct) == %{
             away_type: "object",
             greeting_type: "object",
             away_enabled: "true",
             away_body: "Away right now",
             greeting_enabled: "true"
           }

    legacy_blocks = raw_blocks(legacy)
    correct_blocks = raw_blocks(correct)

    # IDEMPOTENCE: running it again must not re-wrap what it just unwrapped.
    run_migration!()

    assert raw_blocks(legacy) == legacy_blocks,
           "the migration is not idempotent — a second run changed an already-unwrapped row"

    assert raw_blocks(correct) == correct_blocks
    assert column_shape(legacy).away_type == "object"
  end

  # --- end to end ----------------------------------------------------------------------------------

  # The engine's decision core, resolved at runtime: realtime_gateway is not a dep of user_service
  # (and must not become one), but under the umbrella suite the module is loaded.
  defp decide(context),
    do: apply(Module.concat([:RealtimeGateway, :AutoReply]), :decide, [context])

  # The context the consumer builds, with the settings taken VERBATIM from the client seam it uses.
  defp context_for(settings) do
    %{
      conversation_type: "direct",
      conversation_secret?: false,
      sender_id: Ecto.UUID.generate(),
      recipient_id: Ecto.UUID.generate(),
      sender_auto?: false,
      blocked?: false,
      settings: %{
        away: stringify(Map.get(settings, :away)),
        greeting: stringify(Map.get(settings, :greeting))
      },
      contact?: false,
      last_activity_at: nil,
      now: DateTime.utc_now()
    }
  end

  defp stringify(%{} = block), do: Map.new(block, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  @tag :postgres_integration
  test "END-TO-END: a saved rule, read back through the consumer's own load path, SENDS" do
    user = user!()
    assert {:ok, _} = patch(user, %{"away" => @away})

    # The consumer's load path, not the context function: SharedInfra.UserClient is what it calls.
    assert {:ok, settings} = SharedInfra.UserClient.get_auto_replies(%{"user_id" => user})

    assert settings.away["enabled"] == true,
           "the engine's own read path lost `enabled` — this is the two-week bug"

    assert decide(context_for(settings)) == {:send, :away}
  end

  @tag :postgres_integration
  test "END-TO-END on a LEGACY row: decide/1 must NOT answer :disabled" do
    user = user!()
    legacy_row!(user, %{"away" => @away})

    settings =
      capture_log_value(fn ->
        {:ok, settings} = SharedInfra.UserClient.get_auto_replies(%{"user_id" => user})
        settings
      end)

    decision = decide(context_for(settings))

    refute decision == {:skip, :disabled},
           "a legacy double-encoded row still reads as all-defaults — exactly the production skip " <>
             "(`[auto_reply] skip reason=disabled` for a user whose away was enabled)"

    assert decision == {:send, :away}
  end
end

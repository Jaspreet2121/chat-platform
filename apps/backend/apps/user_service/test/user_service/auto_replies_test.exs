defmodule UserService.AutoRepliesTest do
  @moduledoc """
  Auto-reply settings + claim ledger (102) on real SQL: defaults are DISABLED; validation (body
  required when enabled, custom mode requires a valid IANA schedule, midnight-crossing ranges pass,
  bad tz / bad days / bad HH:MM fail, outside_business_hours is the recorded rejection, except_ids
  capped at 100); PATCH replaces per block; and the advisory-lock claim — once per window per
  (user, conversation, kind), across kinds independently, reopening after the window.
  """
  use UserService.DataCase, async: false

  alias UserService.AutoReplies

  @tenant_zero "00000000-0000-0000-0000-000000000001"

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

  @tag :postgres_integration
  test "defaults: no row = both DISABLED with full default shapes" do
    user = user!()
    assert {:ok, settings} = AutoReplies.get_settings(%{"user_id" => user})
    assert settings.away["enabled"] == false
    assert settings.away["mode"] == "always"
    assert settings.away["audience"] == "everyone"
    assert settings.greeting["enabled"] == false
    assert settings.greeting["resend_after_days"] == 14
  end

  @tag :postgres_integration
  test "validation: body required when enabled; outside_business_hours rejected; audience/except rules" do
    user = user!()

    assert {:error, :auto_reply_body_required} =
             patch(user, %{"away" => %{"enabled" => true, "mode" => "always"}})

    assert {:error, :auto_reply_unsupported_mode} =
             patch(user, %{
               "away" => %{"enabled" => true, "mode" => "outside_business_hours", "body" => "x"}
             })

    assert {:error, :auto_reply_invalid} =
             patch(user, %{
               "greeting" => %{"enabled" => true, "body" => "x", "audience" => "vips"}
             })

    too_many = for _ <- 1..101, do: Ecto.UUID.generate()

    assert {:error, :auto_reply_too_many_exceptions} =
             patch(user, %{
               "away" => %{
                 "enabled" => true,
                 "body" => "x",
                 "audience" => "except",
                 "except_ids" => too_many
               }
             })

    # resend_after_days bounds
    assert {:error, :auto_reply_invalid} =
             patch(user, %{
               "greeting" => %{"enabled" => true, "body" => "x", "resend_after_days" => 0}
             })
  end

  @tag :postgres_integration
  test "schedule validation: custom requires it; bad tz/days/HH:MM fail; midnight-crossing passes" do
    user = user!()
    base = %{"enabled" => true, "mode" => "custom", "body" => "Away"}

    assert {:error, :auto_reply_invalid_schedule} = patch(user, %{"away" => base})

    bad_tz =
      Map.put(base, "schedule", %{
        "timezone" => "Mars/Olympus",
        "ranges" => [%{"days" => [1], "start" => "09:00", "end" => "17:00"}]
      })

    assert {:error, :auto_reply_invalid_schedule} = patch(user, %{"away" => bad_tz})

    bad_day =
      Map.put(base, "schedule", %{
        "timezone" => "Asia/Kolkata",
        "ranges" => [%{"days" => [0], "start" => "09:00", "end" => "17:00"}]
      })

    assert {:error, :auto_reply_invalid_schedule} = patch(user, %{"away" => bad_day})

    bad_hm =
      Map.put(base, "schedule", %{
        "timezone" => "Asia/Kolkata",
        "ranges" => [%{"days" => [1], "start" => "25:00", "end" => "17:00"}]
      })

    assert {:error, :auto_reply_invalid_schedule} = patch(user, %{"away" => bad_hm})

    crossing =
      Map.put(base, "schedule", %{
        "timezone" => "Asia/Kolkata",
        "ranges" => [%{"days" => [1, 2, 3, 4, 5], "start" => "22:00", "end" => "06:00"}]
      })

    assert {:ok, saved} = patch(user, %{"away" => crossing})
    assert saved.away["enabled"] == true
    assert saved.away["schedule"]["timezone"] == "Asia/Kolkata"
  end

  @tag :postgres_integration
  test "PATCH replaces the provided block; the other block survives; body truncated to 500" do
    user = user!()
    long = String.duplicate("g", 600)

    assert {:ok, _} = patch(user, %{"greeting" => %{"enabled" => true, "body" => long}})

    assert {:ok, _} =
             patch(user, %{"away" => %{"enabled" => true, "mode" => "always", "body" => "brb"}})

    assert {:ok, settings} = AutoReplies.get_settings(%{"user_id" => user})
    assert settings.greeting["enabled"] == true
    assert String.length(settings.greeting["body"]) == 500
    assert settings.away["body"] == "brb"
  end

  @tag :postgres_integration
  test "CLAIM: once per window per (user, conversation, kind); kinds independent; window reopens" do
    user = user!()
    conversation = Ecto.UUID.generate()

    claim = fn kind, window ->
      AutoReplies.claim(%{
        "user_id" => user,
        "app_id" => @tenant_zero,
        "conversation_id" => conversation,
        "kind" => kind,
        "window_seconds" => window
      })
    end

    assert {:ok, :claimed} = claim.("away", 86_400)
    # The redelivery / racing-evaluator case: same window → throttled, never a second reply.
    assert {:ok, :throttled} = claim.("away", 86_400)

    # A different KIND is its own ledger.
    assert {:ok, :claimed} = claim.("greeting", 14 * 86_400)

    # Another conversation is unaffected.
    assert {:ok, :claimed} =
             AutoReplies.claim(%{
               "user_id" => user,
               "app_id" => @tenant_zero,
               "conversation_id" => Ecto.UUID.generate(),
               "kind" => "away",
               "window_seconds" => 86_400
             })

    # Backdate the away log past the window → claimable again (the 24 h throttle reopening).
    Repo.query!(
      "UPDATE auto_reply_log SET sent_at = now() - interval '25 hours' " <>
        "WHERE user_id = $1::text::uuid AND conversation_id = $2::text::uuid AND kind = 'away'",
      [user, conversation]
    )

    assert {:ok, :claimed} = claim.("away", 86_400)
  end
end

defmodule SharedInfra.AutoReplyWireShapeTest do
  @moduledoc """
  THE WIRE SHAPE of the auto-reply settings blocks across the internal HTTP seam (2026-09-06).

  `SharedInfra.InternalApi.decode_result/2` rehydrates map keys with `String.to_existing_atom/1` and
  falls back to the string when that atom does not exist. For a free-form block that is the worst of
  both worlds: `%{"enabled" => true, "resend_after_days" => 14}` comes back as
  `%{:enabled => true, "resend_after_days" => 14}` — a MIXED map whose contents depend on which
  atoms happen to be loaded in that release. `RealtimeGateway.AutoReply` reads STRING keys, so it
  saw an empty block and skipped every inbound message with `reason=disabled`, while
  `GET /api/v1/auto-replies` looked perfect (atom and string keys serialise to identical JSON).

  So `UserClientHttp` pins these two blocks with `skip_atomize`, exactly as `MessageClientHttp` pins
  a message's `metadata`. These tests assert the real constant it uses — not a copy.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.InternalApi
  alias SharedInfra.UserClientHttp

  # A settings response as UserService.AutoReplies.get_settings/1 returns it: atom top-level keys,
  # STRING keys inside each block.
  @settings %{
    away: %{
      "enabled" => true,
      "mode" => "always",
      "audience" => "everyone",
      "except_ids" => [],
      "schedule" => nil,
      "body" => "Away right now"
    },
    greeting: %{
      "enabled" => false,
      "audience" => "everyone",
      "except_ids" => [],
      "body" => nil,
      "resend_after_days" => 14
    }
  }

  # The real hop: encode as the internal API does, cross a JSON boundary, decode with the options
  # the adapter declares.
  defp round_trip(opts) do
    {:ok, decoded} =
      {:ok, @settings}
      |> InternalApi.encode_result()
      |> Jason.encode!()
      |> Jason.decode!()
      |> InternalApi.decode_result(opts)

    decoded
  end

  test "the adapter's own options keep both blocks STRING-KEYED end to end" do
    decoded = round_trip(UserClientHttp.auto_reply_decode_opts())

    # Top level is still atom-keyed — the consumer reads settings.away.
    assert Map.keys(decoded) |> Enum.sort() == [:away, :greeting]

    # Inside the blocks, EVERY key survives as a string: this is what the engine reads.
    assert decoded.away |> Map.keys() |> Enum.sort() ==
             ["audience", "body", "enabled", "except_ids", "mode", "schedule"]

    assert decoded.greeting |> Map.keys() |> Enum.sort() ==
             ["audience", "body", "enabled", "except_ids", "resend_after_days"]

    # The exact read `RealtimeGateway.AutoReply.enabled?/1` performs.
    assert Map.get(decoded.away, "enabled") == true
    assert Map.get(decoded.greeting, "resend_after_days") == 14
    assert decoded.away == @settings.away
    assert decoded.greeting == @settings.greeting
  end

  test "WITHOUT skip_atomize the blocks are mangled — the bug this pins, stated as a fact" do
    # Make the atoms exist, so this test does not depend on load order elsewhere in the suite.
    _ = [:enabled, :body, :audience]
    decoded = round_trip([])

    # At least one key converted to an atom, so the engine's string read finds nothing.
    assert Map.get(decoded.away, "enabled") == nil
    assert Map.get(decoded.away, :enabled) == true

    refute decoded.away == @settings.away
  end

  test "the option list itself names exactly the two free-form blocks" do
    assert UserClientHttp.auto_reply_decode_opts() == [skip_atomize: ["away", "greeting"]]
  end
end

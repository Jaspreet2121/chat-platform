defmodule ApiGatewayWeb.LinkStoreTest do
  @moduledoc """
  The Redis seam's reply translation — the one piece of the QR flow no test reached.

  Every LinkController test runs against an in-memory store whose get/1 already answers `:not_found`,
  so the flow was proven correct against a translation that was never exercised. Production's
  `SharedInfra.RedisKV.get/1` answers `:miss` for a missing key, this module had no clause for it,
  and a CaseClauseError was the ordinary outcome of a 60s QR expiring.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ApiGatewayWeb.LinkStore.Redis

  # Reads the reply this test wants, in place of SharedInfra.RedisKV.get/1.
  defp reading(reply), do: fn _key -> reply end

  test "A MISSING KEY IS :not_found — the expired-QR path, which used to raise" do
    log = capture_log(fn -> assert Redis.get("link_qr:gone", reading(:miss)) == :not_found end)

    # Handled by its OWN clause, not swept up by the unknown-reply fallback: every 60s QR expires,
    # so an expiry that logged a contract-violation warning would bury the real ones in noise.
    refute log =~ "unexpected store reply"
  end

  test "a stored value comes back as {:ok, value}" do
    assert Redis.get("link_qr:live", reading({:ok, "{\"state\":\"pending\"}"})) ==
             {:ok, "{\"state\":\"pending\"}"}
  end

  test "a store error stays an ERROR — never collapsed into not_found" do
    # The distinction is load-bearing: the controller answers "pending" (keep polling, the link may
    # still be live) for an error and "expired" (mint a new code) for not_found. Collapsing them
    # would tell a browser its perfectly good QR had expired every time Redis hiccuped.
    assert Redis.get("link_qr:x", reading({:error, :closed})) == {:error, :closed}

    assert Redis.get("link_qr:x", reading({:error, :redis_unavailable})) ==
             {:error, :redis_unavailable}
  end

  test "an UNKNOWN reply degrades to not_found and says so in the log" do
    log =
      capture_log(fn ->
        assert Redis.get("link_qr:x", reading({:ok, 42})) == :not_found
      end)

    assert log =~ "[link_qr] unexpected store reply"

    # The same guard, for a shape nobody has invented yet: no clause may fall through again.
    for reply <- [nil, {:ok, :null}, :whatever, {:unexpected, 1}] do
      assert Redis.get("link_qr:x", reading(reply)) == :not_found
    end
  end

  test "get/1 is get/2 over the real reader — the production path is the tested one" do
    # Redis is not configured in the test env, so the real reader errors rather than missing. What
    # matters here is that get/1 COMPOSES the translation instead of carrying its own copy: whatever
    # comes back is one of the contract's three shapes, never a raise.
    assert Redis.get("link_qr:unconfigured") in [:not_found] or
             match?({:error, _}, Redis.get("link_qr:unconfigured"))
  end
end

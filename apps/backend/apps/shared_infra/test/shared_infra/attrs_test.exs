defmodule SharedInfra.AttrsTest do
  @moduledoc """
  The presence-based dual-key read (`SharedInfra.Attrs.get/3`) — the fix for the `Map.get(:a) ||
  Map.get("a")` idiom that silently drops a stored `false`. Covers: false survives under BOTH key forms,
  absent is distinguished from false (default honored), atom form wins when both exist, non-map inputs,
  AND the highest-stakes migrated site as a regression: RateLimiter's per-call `fail_open: false` (the
  enumeration-limiter security control) must reach the adapter as `false`, never as absent.
  """
  use ExUnit.Case, async: false

  alias SharedInfra.Attrs

  test "a stored false survives — under the atom AND the string key form" do
    assert Attrs.get(%{active: false}, :active) == false
    assert Attrs.get(%{"active" => false}, :active) == false
    # The broken idiom this replaces: `false || nil` → nil.
    assert (Map.get(%{active: false}, :active) || Map.get(%{active: false}, "active")) == nil
  end

  test "absent is DISTINGUISHED from false: the default only fires when neither form is present" do
    assert Attrs.get(%{}, :active, :absent) == :absent
    assert Attrs.get(%{active: false}, :active, :absent) == false
    assert Attrs.get(%{"active" => nil}, :active, :absent) == nil
  end

  test "the atom form wins when both are present; non-map input falls to the default" do
    assert Attrs.get(%{:mode => "atom", "mode" => "string"}, :mode) == "atom"
    assert Attrs.get(nil, :mode, :fallback) == :fallback
    assert Attrs.get("not-a-map", :mode) == nil
  end

  test "other falsy-but-present values (0, empty string) survive too" do
    assert Attrs.get(%{"count" => 0}, :count, 99) == 0
    assert Attrs.get(%{name: ""}, :name, "default") == ""
  end

  # --- Regression for the highest-stakes migrated site -------------------------------------------

  defmodule CaptureAdapter do
    @behaviour SharedInfra.RateLimiter
    @impl true
    def check_rate(attrs) do
      send(Process.get(:attrs_test_pid) || self(), {:limiter_attrs, attrs})
      :ok
    end
  end

  test "RateLimiter: fail_open: false (BOTH key forms) reaches the adapter as false — never absent" do
    prev = Application.get_env(:shared_infra, :rate_limiter_adapter)
    Application.put_env(:shared_infra, :rate_limiter_adapter, CaptureAdapter)
    Process.put(:attrs_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:shared_infra, :rate_limiter_adapter, prev),
        else: Application.delete_env(:shared_infra, :rate_limiter_adapter)
    end)

    base = %{"key" => "k", "limit" => 1, "window_seconds" => 60}

    # String-keyed false (the HTTP/JSON form).
    :ok = SharedInfra.RateLimiter.check_rate(Map.put(base, "fail_open", false))
    assert_receive {:limiter_attrs, %{"fail_open" => false}}

    # Atom-keyed false (the in-process form) — the exact shape the old `||` read dropped.
    :ok = SharedInfra.RateLimiter.check_rate(Map.put(base, :fail_open, false))
    assert_receive {:limiter_attrs, %{"fail_open" => false}}

    # Omitted → nil (the global default applies) — false and absent stay distinct.
    :ok = SharedInfra.RateLimiter.check_rate(base)
    assert_receive {:limiter_attrs, attrs}
    assert attrs["fail_open"] == nil
  end
end

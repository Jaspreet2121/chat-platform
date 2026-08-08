defmodule SharedInfra.RuntimeBackendPublicationTest do
  @moduledoc """
  END-TO-END TRACE of the store-backend interlock's config path, as the CONVERSATION release boots
  it — not as this test env happens to have it.

  The chain under proof: the container env carries `MESSAGE_STORE_ADAPTER` → the umbrella's single
  `config/runtime.exs` (baked into every release, conversation's included) runs its
  `config_env() == :prod` block at boot → publishes `:shared_infra, :message_store_backend` —
  `:shared_infra` because that app is in EVERY release, while `:message_service` config would be
  invisible to the conversation container → `ConversationService.InboxCounters.postgres_authoritative?/0`
  reads it and the reconciler interlock closes by KNOWLEDGE (scylla) or correctly RE-OPENS
  (postgres / dual_write, e.g. a rollback).

  This evaluates the REAL runtime.exs with `Config.Reader` under `env: :prod` — the same file, the
  same branch, the release executes. Before the compose slice that pairs with this test, the
  conversation container received no MESSAGE_STORE_ADAPTER at all and the interlock was closed only
  by fail-closed ABSENCE; this pins the path that closes it by knowledge.
  """
  use ExUnit.Case, async: false

  @runtime_exs Path.expand("../../../../config/runtime.exs", __DIR__)

  # runtime.exs's :prod branch fail-fasts on these before it reaches the adapter block; real-shaped
  # throwaway values (require_secret! rejects known placeholder strings).
  @mandatory %{
    "DATABASE_URL" => "ecto://user:pass@localhost/trace_only",
    "SECRET_KEY_BASE" => String.duplicate("kb7", 22),
    "TOKEN_SECRET" => String.duplicate("tk9", 22),
    "OTP_SECRET" => String.duplicate("ot3", 22),
    "PHX_HOST" => "trace.invalid"
  }

  defp read_prod_config!(adapter_value) do
    vars =
      case adapter_value do
        nil -> @mandatory
        value -> Map.put(@mandatory, "MESSAGE_STORE_ADAPTER", value)
      end

    previous = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      Config.Reader.read!(@runtime_exs, env: :prod)
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  # Feed what runtime.exs PUBLISHED into the app env and ask the REAL gate — the same function the
  # reconciler's callers hit. Asserting membership in a literal list here would prove nothing about
  # the code; this proves config-out drives gate-out. (InboxCounters is reachable from this app's
  # tests only because the umbrella test path loads every app; the RELEASE dependency runs the other
  # way, which is the entire reason the key lives under :shared_infra.)
  defp gate_with(published_value) do
    previous = Application.get_env(:shared_infra, :message_store_backend)

    if published_value,
      do: Application.put_env(:shared_infra, :message_store_backend, published_value),
      else: Application.delete_env(:shared_infra, :message_store_backend)

    try do
      ConversationService.InboxCounters.postgres_authoritative?()
    after
      if previous,
        do: Application.put_env(:shared_infra, :message_store_backend, previous),
        else: Application.delete_env(:shared_infra, :message_store_backend)
    end
  end

  test "MESSAGE_STORE_ADAPTER=scylla publishes :shared_infra :message_store_backend at prod boot" do
    config = read_prod_config!("scylla")
    published = config[:shared_infra][:message_store_backend]

    assert published == "scylla"
    # The interlock stays CLOSED — by knowledge now, not by absence.
    refute gate_with(published)
  end

  test "a ROLLBACK to postgres re-opens the interlock — closed by knowledge, not by accident" do
    config = read_prod_config!("postgres")
    published = config[:shared_infra][:message_store_backend]

    assert published == "postgres"
    # The recount backstop comes back exactly when Postgres is authoritative again.
    assert gate_with(published)
  end

  test "with the variable ABSENT nothing is published — the fail-closed state the gate treats as NOT postgres" do
    config = read_prod_config!(nil)
    published = config[:shared_infra][:message_store_backend]

    assert published == nil
    refute gate_with(published)
  end
end

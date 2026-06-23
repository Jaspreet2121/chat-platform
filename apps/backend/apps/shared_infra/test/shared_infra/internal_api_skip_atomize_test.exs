defmodule SharedInfra.InternalApiSkipAtomizeTest do
  @moduledoc """
  The metadata-caveat proof (deterministic, Docker-free): `decode_result/2` with
  `skip_atomize: ["metadata"]` leaves the free-form `metadata` value STRING-keyed while atomizing
  every sibling/structural key — at top level and nested inside lists. Without the option (the other
  adapters' default), keys are fully atomized — proving their behavior is unaffected.
  """
  use ExUnit.Case, async: true

  alias SharedInfra.InternalApi

  test "skip_atomize keeps metadata string-keyed; siblings atomized (top-level message)" do
    envelope = %{
      "ok" => %{
        "message_id" => "m1",
        "conversation_id" => "c1",
        "status" => "active",
        "metadata" => %{"width" => 100, "mime" => "image/png", "nested" => %{"k" => "v"}}
      }
    }

    assert InternalApi.decode_result(envelope, skip_atomize: ["metadata"]) ==
             {:ok,
              %{
                message_id: "m1",
                conversation_id: "c1",
                status: "active",
                metadata: %{"width" => 100, "mime" => "image/png", "nested" => %{"k" => "v"}}
              }}
  end

  test "skip_atomize applies at any depth (metadata inside a messages list)" do
    envelope = %{
      "ok" => %{
        "conversation_id" => "c1",
        "messages" => [
          %{"message_id" => "m1", "metadata" => %{"w" => 1}},
          %{"message_id" => "m2", "metadata" => %{"w" => 2}}
        ]
      }
    }

    assert InternalApi.decode_result(envelope, skip_atomize: ["metadata"]) ==
             {:ok,
              %{
                conversation_id: "c1",
                messages: [
                  %{message_id: "m1", metadata: %{"w" => 1}},
                  %{message_id: "m2", metadata: %{"w" => 2}}
                ]
              }}
  end

  test "without skip_atomize, keys are fully atomized (default for other adapters — unchanged)" do
    envelope = %{"ok" => %{"message_id" => "m1", "metadata" => %{"width" => 1}}}

    assert InternalApi.decode_result(envelope) ==
             {:ok, %{message_id: "m1", metadata: %{width: 1}}}
  end
end

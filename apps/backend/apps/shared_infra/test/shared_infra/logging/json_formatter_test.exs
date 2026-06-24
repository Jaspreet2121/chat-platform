defmodule SharedInfra.Logging.JsonFormatterTest do
  use ExUnit.Case, async: true

  alias SharedInfra.Logging.JsonFormatter

  @ts {{2026, 6, 24}, {12, 30, 45, 123}}

  defp decode(level, message, metadata) do
    JsonFormatter.format(level, message, @ts, metadata)
    |> IO.iodata_to_binary()
    |> String.trim_trailing("\n")
    |> Jason.decode!()
  end

  test "emits one JSON object per line with time/level/message + metadata fields" do
    json = decode(:info, "hello", request_id: "req-1", correlation_id: "corr-1")

    assert json["level"] == "info"
    assert json["message"] == "hello"
    assert json["request_id"] == "req-1"
    assert json["correlation_id"] == "corr-1"
    assert json["time"] == "2026-06-24T12:30:45.123Z"
  end

  test "is robust to non-JSON-encodable metadata (pids/refs/tuples → inspected, never raises)" do
    json = decode(:warning, "weird", correlation_id: "c", pid: self(), tuple: {:a, 1})

    assert json["correlation_id"] == "c"
    assert is_binary(json["pid"])
    assert is_binary(json["tuple"])
  end

  test "stringifies atom values and accepts iodata messages" do
    json = decode(:error, ["io", "data"], status: :down)
    assert json["message"] == "iodata"
    assert json["status"] == "down"
  end
end

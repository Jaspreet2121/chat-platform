defmodule SharedInfra.CorrelationTest do
  # async: false — these read/write per-process Logger metadata.
  use ExUnit.Case, async: false

  alias SharedInfra.Correlation
  alias SharedInfra.InternalApi.CorrelationPlug

  import Plug.Test
  import Plug.Conn

  setup do
    Logger.metadata(correlation_id: nil)
    on_exit(fn -> Logger.metadata(correlation_id: nil) end)
    :ok
  end

  describe "generate/0 and valid?/1" do
    test "generate/0 returns a non-empty lowercase-hex id, distinct each call" do
      a = Correlation.generate()
      b = Correlation.generate()
      assert is_binary(a) and byte_size(a) == 32
      assert a =~ ~r/^[0-9a-f]{32}$/
      assert a != b
    end

    test "valid?/1 accepts a sane string, rejects blank/oversized/non-binary" do
      assert Correlation.valid?("abc-123")
      refute Correlation.valid?("")
      refute Correlation.valid?(nil)
      refute Correlation.valid?(123)
      refute Correlation.valid?(String.duplicate("x", 201))
    end
  end

  describe "get/put/get_or_generate" do
    test "get/0 is nil with no metadata; put/1 sets it; get/0 reads it back" do
      assert Correlation.get() == nil
      Correlation.put("trace-1")
      assert Correlation.get() == "trace-1"
    end

    test "put/1 is a no-op for invalid ids (metadata untouched)" do
      Correlation.put("good")
      Correlation.put("")
      Correlation.put(nil)
      Correlation.put(123)
      assert Correlation.get() == "good"
    end

    test "get_or_generate/0 returns the set id, or a fresh one when unset" do
      assert Correlation.get() == nil
      generated = Correlation.get_or_generate()
      assert is_binary(generated) and generated != ""
      # get_or_generate must NOT mutate metadata.
      assert Correlation.get() == nil

      Correlation.put("trace-2")
      assert Correlation.get_or_generate() == "trace-2"
    end
  end

  describe "CorrelationPlug (service-side header → metadata)" do
    test "reads x-correlation-id into Logger metadata" do
      conn(:post, "/internal/whatever")
      |> put_req_header(Correlation.header(), "inbound-corr-9")
      |> CorrelationPlug.call(CorrelationPlug.init([]))

      assert Correlation.get() == "inbound-corr-9"
    end

    test "leaves metadata untouched when the header is absent" do
      assert Correlation.get() == nil

      conn(:post, "/internal/whatever")
      |> CorrelationPlug.call(CorrelationPlug.init([]))

      assert Correlation.get() == nil
    end
  end
end

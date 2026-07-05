defmodule Engram.Observability.OtelTest do
  use ExUnit.Case, async: true

  alias Engram.Observability.Otel

  describe "sample_ratio/2" do
    test "nil falls back to the default" do
      assert Otel.sample_ratio(nil, 1.0) == 1.0
    end

    test "a valid ratio parses" do
      assert Otel.sample_ratio("0.15", 1.0) == 0.15
      assert Otel.sample_ratio("1.0", 1.0) == 1.0
      assert Otel.sample_ratio("0", 1.0) == 0.0
    end

    test "out-of-range clamps into 0.0..1.0" do
      assert Otel.sample_ratio("2.5", 1.0) == 1.0
      assert Otel.sample_ratio("-0.3", 1.0) == 0.0
    end

    test "garbage falls back to the default" do
      assert Otel.sample_ratio("abc", 1.0) == 1.0
      assert Otel.sample_ratio("", 1.0) == 1.0
    end
  end

  describe "attach_handlers/0" do
    test "installs Phoenix, Ecto, and Bandit instrumentation and returns :ok" do
      assert Otel.attach_handlers() == :ok
    end
  end
end

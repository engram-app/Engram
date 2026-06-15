defmodule Engram.TelemetryTest do
  use ExUnit.Case, async: true

  alias Engram.Telemetry

  describe "error_kind/1" do
    test "passes a bare atom through" do
      assert Telemetry.error_kind(:timeout) == :timeout
      assert Telemetry.error_kind(:no_dek) == :no_dek
    end

    test "returns the leading atom of a 2-tuple" do
      assert Telemetry.error_kind({:badmatch, "secret"}) == :badmatch
    end

    test "returns the leading atom of a larger tuple (e.g. {:paddle_error, status, body})" do
      assert Telemetry.error_kind({:paddle_error, 401, %{"error" => "leak@example.com"}}) ==
               :paddle_error
    end

    test "returns the exception module for an exception struct" do
      assert Telemetry.error_kind(%RuntimeError{message: "boom"}) == RuntimeError
    end

    test "falls back to :other when the leading element is not an atom (never leaks the inner term)" do
      assert Telemetry.error_kind({"secret-string", 1}) == :other
      assert Telemetry.error_kind(%{password: "secret"}) == :other
      assert Telemetry.error_kind("raw string") == :other
    end
  end
end

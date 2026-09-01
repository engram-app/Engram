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

  describe "error_kind/1 on process EXIT reasons" do
    # These are the shapes a dying process actually produces, taken from real
    # exits rather than hand-written. Every one of them used to classify as
    # `:other` — the arm whose whole promise is that the detail rides the log
    # line instead — which is why three callers grew private unwrappers.
    defp opaque(value) do
      send(self(), value)

      receive do
        v -> v
      end
    end

    defp exit_reason(fun) do
      {:exit, reason} =
        Engram.TaskSupervisor
        |> Task.Supervisor.async_nolink(fun)
        |> Task.yield(5_000)

      reason
    end

    test "unwraps a raised exception to its module" do
      assert Telemetry.error_kind(exit_reason(fn -> raise ArgumentError, "boom" end)) ==
               ArgumentError
    end

    test "unwraps a throw to :nocatch" do
      assert Telemetry.error_kind(exit_reason(fn -> throw(:boom) end)) == :nocatch
    end

    test "unwraps a badmatch — the shape `:ok = observe_fun.(room)` produces" do
      # Round-tripped through the mailbox so the type checker cannot fold the
      # match away and warn the clause unreachable — the point here is the
      # RUNTIME exit shape, not the literal.
      assert Telemetry.error_kind(exit_reason(fn -> {:ok, _} = opaque(:error) end)) == :badmatch
    end

    test "unwraps a case_clause" do
      reason = exit_reason(fn -> case :x, do: (:y -> :ok) end)
      assert Telemetry.error_kind(reason) == :case_clause
    end

    test "still lets only an ATOM escape — the inner term never leaks" do
      # `{:badmatch, "a-secret"}` wrapped in an exit pair: the tag escapes, the
      # value does not.
      assert Telemetry.error_kind({{:badmatch, "a-secret"}, []}) == :badmatch
      assert Telemetry.error_kind({{"not-an-atom", 1}, []}) == :other
    end

    test "a struct-less exception map is :other, not a KeyError from inside the classifier" do
      assert Telemetry.error_kind(%{__exception__: true}) == :other
    end

    test "leaves plain exit atoms and tagged exits alone" do
      assert Telemetry.error_kind(:killed) == :killed
      assert Telemetry.error_kind({:shutdown, :closed}) == :shutdown
      assert Telemetry.error_kind({:timeout, {GenServer, :call, [self(), :x, 2000]}}) == :timeout
    end
  end
end

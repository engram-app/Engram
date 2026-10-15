defmodule Engram.Observability.OtelTest do
  use ExUnit.Case, async: false

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
    # The handlers are node-global and outlive this test. Left attached, every
    # later Ecto query and Bandit request in the suite opens a span, and the
    # test config's synchronous simple processor serializes every span end
    # through one process: under load that stalls unrelated tests (a 2 s
    # Bandit telemetry wait, a 120 s Ecto query).
    test "installs Phoenix, Ecto, and Bandit instrumentation and returns :ok" do
      before = otel_handlers()

      # Only what this test attached: a boot-time attach (OTEL endpoint set)
      # stays.
      on_exit(fn ->
        for handler <- otel_handlers() -- before, do: :telemetry.detach(handler.id)
        assert otel_handlers() == before
      end)

      assert Otel.attach_handlers() == :ok

      modules = Enum.map(otel_handlers(), &handler_module/1)

      assert OpentelemetryBandit in modules
      assert OpentelemetryPhoenix in modules
      assert OpentelemetryEcto in modules
    end
  end

  @otel_modules [OpentelemetryBandit, OpentelemetryPhoenix, OpentelemetryEcto]

  defp otel_handlers do
    for handler <- :telemetry.list_handlers([]),
        handler_module(handler) in @otel_modules,
        do: handler
  end

  defp handler_module(%{function: fun}), do: elem(Function.info(fun, :module), 1)

  describe "current_traceparent/0" do
    test "returns a w3c traceparent inside a span, nil outside" do
      require OpenTelemetry.Tracer, as: Tracer
      assert Otel.current_traceparent() == nil

      Tracer.with_span "t" do
        tp = Otel.current_traceparent()
        assert tp =~ ~r/\A00-[0-9a-f]{32}-[0-9a-f]{16}-0[01]\z/
      end
    end
  end
end

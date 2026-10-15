defmodule Engram.Observability.OtelHandlersTest do
  # The OTel handlers are node-global. Left attached, every later Ecto query and
  # Bandit request in the suite opens a span, and the test config's synchronous
  # simple processor serializes every span end through one process: under load
  # that stalls unrelated tests (a 2 s Bandit telemetry wait, a 120 s Ecto
  # query). So: never async, and every handler attached here is detached.
  use ExUnit.Case, async: false

  alias Engram.Observability.Otel

  # The ids the three libraries attach under. Pinned here so a library bump
  # that renames one fails this test instead of leaking past detach_handlers/0.
  @otel_ids MapSet.new([
              {OpentelemetryBandit, :otel_bandit},
              {OpentelemetryPhoenix, :endpoint_start},
              {OpentelemetryPhoenix, :router_dispatch_start},
              {OpentelemetryPhoenix, :live_view},
              {OpentelemetryEcto, [:engram, :repo, :query]}
            ])

  setup do
    before = handler_ids()

    # A boot-time attach (OTEL_EXPORTER_OTLP_ENDPOINT set) would make
    # attach_handlers/0 a no-op we cannot observe, and detaching would strip
    # the boot handlers.
    assert MapSet.disjoint?(before, @otel_ids),
           "OTel handlers are already attached (OTEL_EXPORTER_OTLP_ENDPOINT set?); " <>
             "unset it to run this test: #{inspect(MapSet.intersection(before, @otel_ids))}"

    on_exit(fn ->
      assert Otel.detach_handlers() == :ok

      for id <- MapSet.difference(handler_ids(), before),
          do: assert(:telemetry.detach(id) == :ok)

      assert handler_ids() == before
    end)

    %{before: before}
  end

  test "attach_handlers/0 attaches the Bandit, Phoenix, and Ecto handlers", %{before: before} do
    assert Otel.attach_handlers() == :ok
    assert MapSet.difference(handler_ids(), before) == @otel_ids
  end

  test "detach_handlers/0 removes everything attach_handlers/0 attached", %{before: before} do
    :ok = Otel.attach_handlers()
    assert Otel.detach_handlers() == :ok
    assert handler_ids() == before
  end

  test "detach_handlers/0 is :ok when nothing is attached", %{before: before} do
    assert Otel.detach_handlers() == :ok
    assert handler_ids() == before
  end

  defp handler_ids, do: :telemetry.list_handlers([]) |> MapSet.new(& &1.id)
end

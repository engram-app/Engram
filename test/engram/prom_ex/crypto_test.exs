defmodule Engram.PromEx.CryptoTest do
  @moduledoc """
  Verifies the Crypto PromEx plugin metric shape.

  Event emission is covered by `Engram.Crypto.DekCacheTest` (dek_cache
  hit/miss) and `Engram.CryptoTest` (decrypt_notes_batch). The
  plugin-shape test below is what guards Prometheus registration —
  `EngramWeb.Telemetry.metrics/0` feeds LiveDashboard only, so without
  this plugin the events never reach the scraped /metrics endpoint.
  """
  use ExUnit.Case, async: true

  alias Engram.PromEx.Crypto, as: CryptoPlugin
  alias PromEx.MetricTypes.Event

  describe "event_metrics/1" do
    test "returns Event struct(s) prefixed [:engram, :prom_ex, :crypto]" do
      events = CryptoPlugin.event_metrics(otp_app: :engram) |> List.wrap()
      assert Enum.all?(events, &match?(%Event{}, &1))
      metrics = Enum.flat_map(events, & &1.metrics)
      assert Enum.any?(metrics, fn m -> Enum.at(m.name, 2) == :crypto end)
    end

    test "declares an outcome-tagged counter on [:engram, :crypto, :dek_cache]" do
      metrics =
        CryptoPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Counter{}, m) and
                 m.event_name == [:engram, :crypto, :dek_cache] and
                 :outcome in m.tags
             end)
    end

    test "declares kind-tagged duration + batch-size distributions on decrypt_batch" do
      metrics =
        CryptoPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      target = [:engram, :crypto, :decrypt_batch]

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Distribution{}, m) and m.event_name == target and
                 m.measurement == :duration_us and :kind in m.tags
             end)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.Distribution{}, m) and m.event_name == target and
                 m.measurement == :count and :kind in m.tags
             end)
    end

    # A blocked gate turns compression off fleet-wide with one log line; the
    # gauge is what an alert can watch. `allowed` is untagged so its last
    # value is the verdict; the reason is one-hot (the gate emits every
    # reason), so a stale reason series reads 0, never a stale 1.
    test "declares the compression gate verdict and reason gauges" do
      metrics =
        CryptoPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.LastValue{}, m) and
                 m.name == [:engram, :prom_ex, :crypto, :compression_gate, :allowed] and
                 m.event_name == [:engram, :envelope, :compression_gate] and
                 m.measurement == :allowed and m.tags == []
             end)

      assert Enum.any?(metrics, fn m ->
               match?(%Telemetry.Metrics.LastValue{}, m) and
                 m.name == [:engram, :prom_ex, :crypto, :compression_gate, :reason] and
                 m.event_name == [:engram, :envelope, :compression_gate, :reason] and
                 m.measurement == :current and m.tags == [:reason]
             end)
    end

    test "no per-tenant tags" do
      metrics =
        CryptoPlugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)

      banned = [:user_id, :vault_id, :note_id, :tenant_id]

      for m <- metrics, tag <- m.tags do
        refute tag in banned, "Crypto metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
      end
    end
  end

  describe "registration" do
    test "plugin is wired into Engram.PromEx" do
      assert Engram.PromEx.Crypto in Engram.PromEx.plugins()
    end
  end
end

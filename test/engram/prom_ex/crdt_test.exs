defmodule Engram.PromEx.CrdtTest do
  @moduledoc """
  The CRDT plugin's polling group (#1493).

  Every other CRDT room signal is a COUNTER — rooms started, rooms drained. A
  counter answers "how many arrived" and can never answer "how many are here
  now", which is the question a memory backstop is tuned against. The 2026-08-28
  prod sync peaked at 314 resident rooms against a cap of 64 and the only record
  of it is a `Logger.warning` line; nothing was scrapeable, so nothing could
  alert. These tests pin the gauge that closes that.
  """
  use ExUnit.Case, async: true

  alias Engram.Notes.CrdtRoomLru
  alias Engram.PromEx.Crdt, as: Plugin
  alias Engram.Test.PromExMetrics
  alias PromEx.MetricTypes.Polling

  defp polling, do: Plugin.polling_metrics(otp_app: :engram) |> List.wrap()

  test "records each update-log append's size, untagged" do
    metrics = Plugin.event_metrics(otp_app: :engram) |> List.wrap() |> Enum.flat_map(& &1.metrics)
    m = Enum.find(metrics, &(&1.name == [:engram, :prom_ex, :crdt, :update, :bytes]))
    assert %Telemetry.Metrics.Distribution{event_name: [:engram, :crdt, :update_appended]} = m
    assert m.tags == []
  end

  test "is registered in the PromEx plugin list (else metrics never reach /metrics)" do
    assert Plugin in Engram.PromEx.plugins()
  end

  test "returns a Polling group with resident + cap last_value gauges" do
    groups = polling()
    assert groups != []
    assert Enum.all?(groups, &match?(%Polling{}, &1))

    metrics = Enum.flat_map(groups, & &1.metrics)
    names = Enum.map(metrics, & &1.name)

    assert [:engram, :prom_ex, :crdt, :rooms, :resident] in names
    assert [:engram, :prom_ex, :crdt, :rooms, :cap] in names
    assert Enum.all?(metrics, &match?(%Telemetry.Metrics.LastValue{}, &1))
  end

  test "no per-tenant / unbounded tags on the polled gauges" do
    banned = [:user_id, :vault_id, :note_id, :doc_id, :path, :tenant_id]

    for group <- polling(), m <- group.metrics, tag <- m.tags do
      refute tag in banned, "metric #{inspect(m.name)} has banned tag #{inspect(tag)}"
    end
  end

  test "execute_room_metrics/0 emits resident alongside the cap it is judged against" do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:engram, :crdt, :rooms],
      fn _name, meas, _meta, _ -> send(test_pid, {:rooms, ref, meas}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)

    Plugin.execute_room_metrics()

    # The cap ships WITH the count on purpose: overshoot is the signal, and a
    # dashboard that hardcodes 64 silently lies the day the config changes.
    assert_receive {:rooms, ^ref, %{resident: resident, cap: cap}}, 1000
    assert is_integer(resident) and resident >= 0
    assert cap == CrdtRoomLru.max_resident()
  end

  # engram-app/Engram-obsidian#645. The channel emits the crdt_create reply
  # outcome; without this counter it never reaches /metrics.
  test "genesis_reply is exported as a counter tagged by outcome and client" do
    metrics = PromExMetrics.of(Plugin) |> List.wrap() |> Enum.flat_map(& &1.metrics)
    m = Enum.find(metrics, &(&1.event_name == [:engram, :crdt, :genesis_reply]))

    # A sum, not a counter: ZeroInit's boot 0 must not count as a reply.
    assert %Telemetry.Metrics.Sum{measurement: :count} = m
    assert m.name == [:engram, :prom_ex, :crdt, :genesis_reply, :total]
    assert m.tags == [:outcome, :client]
  end

  test "genesis_reply reaches /metrics with its outcome and client labels" do
    before = genesis_reply_value("occupied", "web")

    :telemetry.execute([:engram, :crdt, :genesis_reply], %{count: 1}, %{
      outcome: :occupied,
      client: :web
    })

    # >=, not ==: async channel tests can emit the same pair concurrently.
    assert genesis_reply_value("occupied", "web") >= before + 1
  end

  # Label order on the line is the storage adapter's choice, so match each.
  defp genesis_reply_value(outcome, client) do
    Engram.PromEx
    |> PromEx.get_metrics()
    |> IO.iodata_to_binary()
    |> String.split("\n")
    |> Enum.find_value(0, fn line ->
      String.starts_with?(line, "engram_prom_ex_crdt_genesis_reply_total{") and
        line =~ ~s(outcome="#{outcome}") and line =~ ~s(client="#{client}") and
        line |> String.split(" ") |> List.last() |> String.to_integer()
    end)
  end

  # #1706. The emit is useless if the plugin never exports it: nothing in the
  # checkpoint path would fail, and the Grafana panel would just be empty.
  test "checkpoint_doc bloat distributions are exported, untagged" do
    metrics =
      [otp_app: :engram]
      |> then(&PromExMetrics.of(Plugin, &1))
      |> List.wrap()
      |> Enum.flat_map(& &1.metrics)
      |> Enum.filter(&(&1.event_name == [:engram, :crdt, :checkpoint_doc]))

    assert Enum.all?(metrics, &match?(%Telemetry.Metrics.Distribution{}, &1))

    measurements = Enum.map(metrics, & &1.measurement)
    assert :bloat_ratio in measurements
    assert :state_bytes in measurements
    assert :content_bytes in measurements
    assert :client_count in measurements

    # Untagged by contract — one series per bucket, never one per note.
    assert Enum.all?(metrics, &(&1.tags == []))
  end

  # The sweep gauges are the unbiased half of #1706. Same failure mode as the
  # histograms: an unexported metric breaks nothing and shows nothing.
  test "state_sweep gauges are exported, untagged" do
    metrics =
      [otp_app: :engram]
      |> then(&PromExMetrics.of(Plugin, &1))
      |> List.wrap()
      |> Enum.flat_map(& &1.metrics)
      |> Enum.filter(&(&1.event_name == [:engram, :crdt, :state_sweep]))

    assert Enum.all?(metrics, &match?(%Telemetry.Metrics.LastValue{}, &1))
    assert Enum.all?(metrics, &(&1.tags == []))

    measurements = Enum.map(metrics, & &1.measurement)

    for key <- [
          :measured_at_unix,
          :notes,
          :notes_with_state,
          :notes_measured,
          :bloat_ratio_p50,
          :bloat_ratio_p90,
          :bloat_ratio_p99,
          :bloat_ratio_max,
          :notes_over_threshold,
          :notes_save_rate_over_threshold,
          :save_rate_max_per_hour,
          :state_bytes_total,
          :content_bytes_total
        ] do
      assert key in measurements, "missing sweep gauge for #{key}"
    end
  end
end

defmodule Engram.PromEx.NativeTest do
  use ExUnit.Case, async: true

  alias Engram.PromEx.Native
  alias Engram.Test.PromExMetrics
  alias PromEx.MetricTypes.{Event, Polling}

  test "is a registered PromEx plugin" do
    assert Native in Engram.PromEx.plugins()
  end

  test "the poll emits [:engram, :vm, :native_memory] with the memory snapshot" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :vm, :native_memory]])
    :ok = Native.execute_native_memory()

    assert_receive {[:engram, :vm, :native_memory], ^ref,
                    %{rss: rss, erlang_total: total, nif_live: live, unaccounted: gap}, %{}}

    # `unaccounted` can be NEGATIVE: the BEAM counts memory it has allocated,
    # some of which the OS has not made resident yet. Only its trend matters.
    assert rss > 0 and gap == rss - total and is_integer(live)
  end

  test "the poll emits [:engram, :nif, :envelope] per counted NIF" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :envelope]])
    :ok = Native.execute_envelope_counts()

    for nif <- [:envelope_seal, :envelope_open] do
      assert_receive {[:engram, :nif, :envelope], ^ref, %{calls: calls, input_bytes: bytes},
                      %{nif: ^nif}}

      assert is_integer(calls) and is_integer(bytes)
    end
  end

  test "metric definitions build" do
    opts = [otp_app: :engram]
    assert %Event{metrics: metrics} = PromExMetrics.of(Native, opts)
    for m <- metrics, do: assert(m.tags == [:nif, :dirty])

    # Count + microsecond sum stay (cheap averages); the two histograms add
    # the per-call shape, so the slowest/largest single call is visible.
    assert [
             %Telemetry.Metrics.Counter{name: [:engram, :prom_ex, :nif, :call, :total]},
             %Telemetry.Metrics.Sum{
               name: [:engram, :prom_ex, :nif, :call, :duration, :microseconds, :total]
             },
             %Telemetry.Metrics.Distribution{
               name: [:engram, :prom_ex, :nif, :call, :duration, :milliseconds]
             } = duration,
             %Telemetry.Metrics.Distribution{
               name: [:engram, :prom_ex, :nif, :call, :input, :bytes],
               measurement: :input_bytes
             } = bytes
           ] = metrics

    # 1 ms to 60 s: a ~9 MB note's keyword_encode must not fall into +Inf.
    les = duration.reporter_options[:buckets]
    assert hd(les) == 1 and List.last(les) == 60_000
    assert duration.measurement == :duration
    assert duration.unit == {:native, :millisecond}
    assert List.last(bytes.reporter_options[:buckets]) >= 16_777_216

    assert [%Polling{}, %Polling{}] = Native.polling_metrics(opts)
  end

  # A nif name no real call uses, so concurrent tests cannot move its series.
  test "a call event records one duration and one input-bytes sample per nif and dirty" do
    :telemetry.execute(
      [:engram, :nif, :call, :stop],
      %{
        duration: System.convert_time_unit(2_000, :millisecond, :native),
        native_peak_bytes: 0,
        input_bytes: 5_000_000
      },
      %{nif: :histogram_probe, dirty: true}
    )

    body = Engram.PromEx |> PromEx.get_metrics() |> IO.iodata_to_binary()

    for {name, sum} <- [
          {"engram_prom_ex_nif_call_duration_milliseconds", 2_000},
          {"engram_prom_ex_nif_call_input_bytes", 5_000_000}
        ] do
      series = sample_lines(body, name, "histogram_probe")
      assert [1] = for({"_count", v} <- series, do: round(v))
      assert [^sum] = for({"_sum", v} <- series, do: round(v))
    end
  end

  # `[{suffix, value}]` for the dirty="true" series of one nif.
  defp sample_lines(body, name, nif) do
    for line <- String.split(body, "\n"),
        [_, suffix, labels, v] <- [Regex.run(~r/^#{name}(_count|_sum)\{(.*)\} (\S+)$/, line)],
        labels =~ ~s(nif="#{nif}") and labels =~ ~s(dirty="true"),
        do: {suffix, v |> Float.parse() |> elem(0)}
  end
end

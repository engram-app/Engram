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

    # Count + microsecond sum stay (cheap averages). One duration histogram,
    # kept to the suspect NIFs: a histogram is 10 series per nif/dirty pair.
    assert [
             %Telemetry.Metrics.Counter{name: [:engram, :prom_ex, :nif, :call, :total]},
             %Telemetry.Metrics.Sum{
               name: [:engram, :prom_ex, :nif, :call, :duration, :microseconds, :total]
             },
             %Telemetry.Metrics.Distribution{
               name: [:engram, :prom_ex, :nif, :call, :duration, :milliseconds]
             } = duration
           ] = metrics

    # Up to 60 s: a ~9 MB note's keyword_encode must not fall into +Inf.
    assert duration.reporter_options[:buckets] == [10, 100, 500, 1_000, 2_500, 10_000, 60_000]
    # Telemetry.Metrics keeps the TARGET unit and wraps `measurement` in a
    # native->ms conversion, so check the behaviour, not the atom.
    assert duration.unit == :millisecond
    assert duration.tags == [:nif, :dirty]
    native_1500ms = System.convert_time_unit(1_500, :millisecond, :native)
    assert duration.measurement.(%{duration: native_1500ms}) == 1_500

    for nif <- [:keyword_encode, :chunk], do: assert(duration.keep.(%{nif: nif, dirty: true}))
    for nif <- [:pack_f32, :zz_budget], do: refute(duration.keep.(%{nif: nif, dirty: false}))

    assert [%Polling{}, %Polling{}] = Native.polling_metrics(opts)
  end

  # dirty: false is a series no real keyword_encode caller emits (it is always
  # dirty), so concurrent tests cannot move it; deltas guard the rest.
  test "a keyword_encode call event records one duration sample" do
    name = "engram_prom_ex_nif_call_duration_milliseconds"
    before = duration_samples(name)

    :telemetry.execute(
      [:engram, :nif, :call, :stop],
      %{
        duration: System.convert_time_unit(2_000, :millisecond, :native),
        native_peak_bytes: 0,
        input_bytes: 5_000_000
      },
      %{nif: :keyword_encode, dirty: false}
    )

    after_ = duration_samples(name)
    assert after_.count - before.count == 1
    assert after_.sum - before.sum == 2_000
  end

  # `%{count, sum}` of the nif="keyword_encode",dirty="false" series, 0 if absent.
  defp duration_samples(name) do
    body = Engram.PromEx |> PromEx.get_metrics() |> IO.iodata_to_binary()

    for line <- String.split(body, "\n"),
        [_, suffix, labels, v] <- [Regex.run(~r/^#{name}(_count|_sum)\{(.*)\} (\S+)$/, line)],
        labels =~ ~s(nif="keyword_encode") and labels =~ ~s(dirty="false"),
        reduce: %{count: 0, sum: 0} do
      acc ->
        n = v |> Float.parse() |> elem(0) |> round()
        if suffix == "_count", do: %{acc | count: n}, else: %{acc | sum: n}
    end
  end
end

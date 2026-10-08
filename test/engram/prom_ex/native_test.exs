defmodule Engram.PromEx.NativeTest do
  use ExUnit.Case, async: true

  alias Engram.PromEx.Native
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
    assert %Event{} = Native.event_metrics(opts)
    assert [%Polling{}, %Polling{}] = Native.polling_metrics(opts)
  end
end

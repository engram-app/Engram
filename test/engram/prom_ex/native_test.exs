defmodule Engram.PromEx.NativeTest do
  use ExUnit.Case, async: true

  test "is a registered PromEx plugin" do
    assert Engram.PromEx.Native in Engram.PromEx.plugins()
  end

  test "the poll emits [:engram, :vm, :native_memory] with the memory snapshot" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :vm, :native_memory]])
    :ok = Engram.PromEx.Native.execute_native_memory()

    assert_receive {[:engram, :vm, :native_memory], ^ref,
                    %{rss: rss, erlang_total: total, nif_live: live, unaccounted: gap}, %{}}

    assert rss > total and gap == rss - total and is_integer(live)
  end

  test "metric definitions build" do
    opts = [otp_app: :engram]
    assert %PromEx.MetricTypes.Event{} = Engram.PromEx.Native.event_metrics(opts)
    assert %PromEx.MetricTypes.Polling{} = Engram.PromEx.Native.polling_metrics(opts)
  end
end

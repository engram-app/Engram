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
  alias PromEx.MetricTypes.Polling

  defp polling, do: Plugin.polling_metrics(otp_app: :engram) |> List.wrap()

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
end

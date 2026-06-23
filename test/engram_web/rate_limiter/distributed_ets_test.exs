defmodule EngramWeb.RateLimiter.DistributedETSTest do
  use ExUnit.Case, async: false
  alias EngramWeb.RateLimiter.DistributedETS

  setup do
    start_supervised!({DistributedETS, [clean_period: :timer.minutes(1)]})
    # Hammer's ETS table is created synchronously in init/1, so start_supervised!
    # returning is sufficient. Synchronize against the Listener to ensure it is
    # subscribed before any test sends messages.
    _ = :sys.get_state(EngramWeb.RateLimiter.DistributedETS.Listener)
    :ok
  end

  test "allows under limit then denies over limit" do
    key = "preauth:#{System.unique_integer([:positive])}"
    assert {:allow, 1} = DistributedETS.hit(key, 1000, 2)
    assert {:allow, 2} = DistributedETS.hit(key, 1000, 2)
    assert {:deny, _retry_ms} = DistributedETS.hit(key, 1000, 2)
  end

  test "a local hit counts exactly once (self is excluded from its own broadcast)" do
    key = "rps:#{System.unique_integer([:positive])}"
    # If the local Listener received its own broadcast, this would count 2.
    assert {:allow, 1} = DistributedETS.hit(key, 1000, 10)
  end

  test "a remote :inc message applies to the local counter" do
    key = "remote:#{System.unique_integer([:positive])}"
    send(Process.whereis(DistributedETS.Listener), {:inc, key, 1000, 1})
    # Flush the Listener mailbox so the :inc is applied before the assertion.
    _ = :sys.get_state(Process.whereis(DistributedETS.Listener))
    # The remote inc consumed one slot; with limit 1 the next local hit denies.
    assert {:deny, _} = DistributedETS.hit(key, 1000, 1)
  end

  describe "telemetry — [:engram, :rate_limiter, :remote_inc]" do
    # Cross-node sync / warm-window signal (#687): a freshly-joined node starts
    # with an EMPTY ETS table and no handoff, so this counter is the only proof
    # it begins applying peer increments from PubSub-subscribe time (boot).
    defp attach_remote_inc(ref) do
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :rate_limiter, :remote_inc],
        fn _name, meas, meta, _ -> send(test_pid, {:remote_inc, ref, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    end

    test "a remote :inc that applies emits :applied" do
      ref = make_ref()
      attach_remote_inc(ref)
      key = "remote:#{System.unique_integer([:positive])}"

      send(Process.whereis(DistributedETS.Listener), {:inc, key, 1000, 1})
      _ = :sys.get_state(Process.whereis(DistributedETS.Listener))
      assert_receive {:remote_inc, ^ref, %{count: 1}, %{result: :applied}}, 1000
    end

    test "a remote :inc that fails to apply emits :dropped" do
      ref = make_ref()
      attach_remote_inc(ref)
      key = "remote:#{System.unique_integer([:positive])}"

      # Force Local.inc/3 to raise: the Hammer ETS table is named after the
      # Local module; deleting it makes the next counter write raise ArgumentError,
      # exercising the Listener's rescue (drop) path deterministically.
      :ets.delete(DistributedETS.Local)
      send(Process.whereis(DistributedETS.Listener), {:inc, key, 1000, 1})
      _ = :sys.get_state(Process.whereis(DistributedETS.Listener))
      assert_receive {:remote_inc, ^ref, %{count: 1}, %{result: :dropped}}, 1000
    end
  end
end

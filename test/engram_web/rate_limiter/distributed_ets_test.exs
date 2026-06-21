defmodule EngramWeb.RateLimiter.DistributedETSTest do
  use ExUnit.Case, async: false
  alias EngramWeb.RateLimiter.DistributedETS

  setup do
    start_supervised!({DistributedETS, [clean_period: :timer.minutes(1)]})
    # Hammer's ETS table is created asynchronously in handle_continue.
    Process.sleep(50)
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
    Process.sleep(20)
    # The remote inc consumed one slot; with limit 1 the next local hit denies.
    assert {:deny, _} = DistributedETS.hit(key, 1000, 1)
  end
end

defmodule Engram.NativeLeak do
  @moduledoc false
  import ExUnit.Assertions

  # The regex crate keeps match caches in a pool: an owner slot plus 8
  # stacks picked by thread id. A cache is created, and kept for the life of
  # the library, the first time a call on a thread finds its stack empty. A
  # test process migrates between scheduler threads, so a cold one read as a
  # ~48 KB "leak" mid-measurement. Concurrent warm-up is not enough: tasks
  # bunched onto 2 of 10 schedulers, and contended pops hand out throwaway
  # caches. So warm each scheduler in turn, one process pinned to it
  # (`spawn_opt` `{:scheduler, id}`), then assert `calls` more calls leave
  # the counter unchanged.
  def assert_no_leak(fun, calls \\ 300) do
    for id <- 1..System.schedulers_online() do
      warm = fn ->
        fun.()
        fun.()
      end

      {pid, ref} = :erlang.spawn_opt(warm, [:monitor, {:scheduler, id}])
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    end

    before = Engram.Native.live_bytes()
    for _ <- 1..calls, do: fun.()
    assert Engram.Native.live_bytes() - before == 0
  end
end

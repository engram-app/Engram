defmodule Engram.NativeLeak do
  @moduledoc false
  import ExUnit.Assertions

  # Some native memory is kept on purpose the first time a call lands on a
  # thread: the regex crate's match caches (a pool of 8 stacks picked by
  # thread id) and the envelope's thread-local zstd contexts. Most NIFs run
  # on a dirty CPU scheduler, and which dirty thread runs a call is not
  # something a test can choose (`{:scheduler, id}` pins the NORMAL
  # scheduler only). So no warm-up is guaranteed to reach every thread: a
  # thread first used mid-measurement kept a ~74 KB cache and read as a leak.
  #
  # That memory is bounded (one cache per stack per thread); a leak grows on
  # every call. So: run windows of `calls` calls until one leaves the counter
  # unchanged. A leak never produces such a window, so it fails all of them.
  def assert_no_leak(fun, calls \\ 300, windows \\ 10) do
    deltas =
      Enum.reduce_while(1..windows, [], fn _, acc ->
        before = Engram.Native.live_bytes()
        for _ <- 1..calls, do: fun.()

        case Engram.Native.live_bytes() - before do
          0 -> {:halt, :settled}
          delta -> {:cont, [delta | acc]}
        end
      end)

    assert deltas == :settled,
           "native heap grew in all #{windows} windows of #{calls} calls: " <>
             "#{inspect(Enum.reverse(List.wrap(deltas)))} bytes"
  end
end

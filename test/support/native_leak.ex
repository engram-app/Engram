defmodule Engram.NativeLeak do
  @moduledoc false
  import ExUnit.Assertions

  # Lazy statics (compiled regexes) and the regex crate's per-thread match
  # caches live as long as the library. They are bounded, but each is
  # allocated the first time a call lands on a scheduler thread, and a test
  # process migrates between threads: the leak counter then read up to
  # ~670 KB on a run that leaked nothing. So warm every thread with
  # concurrent calls first; growth over `calls` more calls is then a leak.
  def assert_no_leak(fun, calls \\ 300) do
    n = System.schedulers_online() * 8

    1..n
    |> Task.async_stream(fn _ -> fun.() end, max_concurrency: n, ordered: false)
    |> Stream.run()

    before = Engram.Native.live_bytes()
    for _ <- 1..calls, do: fun.()
    assert Engram.Native.live_bytes() - before == 0
  end
end

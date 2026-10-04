defmodule Engram.Native.MmrSelectTest do
  # async: false — the leak test reads a process-wide counter.
  use ExUnit.Case, async: false

  defp pool(n, dims) do
    :rand.seed(:exsss, {n, dims, 1})
    vectors = for _ <- 1..n, do: for(_ <- 1..dims, do: :rand.uniform() - 0.5)
    scores = for i <- 1..n, do: 1.0 - i / (n + 1)
    {vectors, scores}
  end

  describe "memory standard" do
    # The pool is bounded by the search's candidate_pool; the NIF holds it as
    # f64s once and normalizes in place.
    test "native peak stays within a small multiple of the pool's f64 size" do
      {vectors, scores} = pool(400, 1024)
      {picked, peak} = Engram.Native.mmr_select_nif(vectors, scores, 100, 0.3)
      assert length(picked) == 100
      assert peak <= 2 * (400 * 1024 * 8) + 65_536
    end

    test "repeated calls leak nothing" do
      {vectors, scores} = pool(20, 64)
      Engram.Native.mmr_select_nif(vectors, scores, 5, 0.3)
      before = Engram.Native.live_bytes()
      for _ <- 1..300, do: Engram.Native.mmr_select_nif(vectors, scores, 5, 0.3)
      assert Engram.Native.live_bytes() - before == 0
    end

    test "every call emits [:engram, :nif, :call, :stop]" do
      ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :nif, :call, :stop]])
      Engram.Native.mmr_select([[1.0, 0.0], nil], [0.9, 0.8], 2, 0.5)

      assert_received {[:engram, :nif, :call, :stop], ^ref, %{input_bytes: 48},
                       %{nif: :mmr_select}}
    end
  end

  test "mismatched vector and score counts are refused" do
    assert_raise ArgumentError, fn ->
      Engram.Native.mmr_select_nif([[1.0]], [0.9, 0.8], 2, 0.5)
    end
  end

  # #1798: ~2.5 s in Elixir. Wall-clock is noisy under suite load, so the
  # budget is loose; the point is orders of magnitude, not milliseconds.
  test "a limit-50 rerank over 200 x 1024 runs in well under a second" do
    {vectors, scores} = pool(200, 1024)

    {us, {picked, _}} =
      :timer.tc(fn -> Engram.Native.mmr_select_nif(vectors, scores, 50, 0.3) end)

    assert length(picked) == 50
    assert us < 500_000, "mmr_select took #{div(us, 1000)} ms"
  end
end

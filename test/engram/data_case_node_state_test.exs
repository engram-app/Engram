defmodule Engram.DataCaseNodeStateTest do
  @moduledoc """
  A sync test starts with the rebuild gate's node-global inputs cold: the
  maintenance token bucket unspent and no cached `:rebuild` verdict.

  Both tests check the start state, then leave it spent. Whichever runs
  second fails unless `Engram.DataCase` resets it, so this needs no fixed
  order. Without the reset, a test that spends the bucket
  (`RebuildStaleNoteV5Test`, `EmbedModelsTest`) snoozed every later gated
  rebuild in the same minute (`RebuildLedgerWiringTest`, CI run 41968893624).

  async: false: it spends node-global state on purpose.
  """
  use Engram.DataCase, async: false

  alias EngramWeb.RateLimiter

  @tpm_key "voyage_maintenance_tpm"

  for name <- ["first", "second"] do
    test "#{name} test starts with the bucket unspent and the gate cache cold" do
      assert {:allow, 1} = RateLimiter.hit(@tpm_key, 60_000, 150_000, :voyage_embed)
      assert :miss = Engram.Cache.get(:rebuild, :pass_done)

      RateLimiter.hit(@tpm_key, 60_000, 150_000, :voyage_embed, 200_000)
      Engram.Cache.put(:rebuild, :pass_done, true)
    end
  end

  # The reset runs before every sync test (~5,400 of them, one at a time), so
  # it must not take `reset_buckets!/0`'s fresh-window wait: inside the last
  # second of a 10 s window that sleeps up to 1 s. Start the call there.
  test "the per-test reset does not wait for a fresh window" do
    await_window_tail()
    {us, :ok} = :timer.tc(&Engram.DataCase.reset_rebuild_gate/0)
    assert us < 100_000, "reset took #{div(us, 1000)} ms"
  end

  defp await_window_tail do
    if rem(System.system_time(:millisecond), 10_000) in 9_100..9_700 do
      :ok
    else
      Process.sleep(20)
      await_window_tail()
    end
  end
end

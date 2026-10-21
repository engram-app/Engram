defmodule Engram.PromEx.RebuildLedgerTest do
  @moduledoc """
  The v5 rebuild ledger on /metrics: budget and spent tokens as gauges, so
  infra can alert on spend past 1.1x the manifest (budget / 1.15), and the
  halt counter's exported name.

  async: false: the gauges are global PromEx state.
  """
  use Engram.DataCase, async: false

  alias Engram.PromEx.Indexing
  alias Engram.Rebuild

  setup do
    Engram.Cache.clear_local(:rebuild)
    Repo.query!("DELETE FROM rebuild_ledger")
    :ok
  end

  defp scrape, do: Engram.PromEx |> PromEx.get_metrics() |> IO.iodata_to_binary()

  defp value(scrape, metric) do
    case Regex.run(~r/^#{metric} (\S+)$/m, scrape) do
      [_, v] -> v |> Float.parse() |> elem(0)
      nil -> nil
    end
  end

  test "budget and spent tokens are exported as gauges" do
    Rebuild.set_budget(1_150_000)
    assert Rebuild.debit(4_321) == :ok

    assert Indexing.execute_rebuild_ledger() == :ok

    scrape = scrape()
    assert value(scrape, "engram_prom_ex_indexing_rebuild_ledger_budget_tokens") == 1_150_000.0
    assert value(scrape, "engram_prom_ex_indexing_rebuild_ledger_spent_tokens") == 4_321.0
  end

  test "no ledger emits nothing and does not raise" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:engram, :rebuild, :ledger]])

    assert Indexing.execute_rebuild_ledger() == :ok
    refute_received {[:engram, :rebuild, :ledger], ^ref, _, _}
  end

  test "an unreadable ledger is skipped, never raised into the poller" do
    # A bare process (no `$callers`, so no sandbox allowance): the read raises.
    me = self()
    spawn(fn -> send(me, {:polled, Indexing.execute_rebuild_ledger()}) end)
    assert_receive {:polled, :ok}
  end

  test "a halt is counted as engram_prom_ex_indexing_rebuild_halted_total" do
    Rebuild.set_budget(1)
    assert Rebuild.debit(2) == :halt

    assert scrape() =~ ~r/^engram_prom_ex_indexing_rebuild_halted_total \d+/m
  end
end

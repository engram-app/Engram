defmodule Engram.RebuildLedgerRaceTest do
  @moduledoc """
  `Rebuild.debit/1` on REAL, separately committing connections: the sandbox
  serializes every task on one connection, so a read-then-write debit would
  pass there and overspend in prod.

  Determinism from a row lock, as in `Engram.OAuthRotationRaceTest`: a holder
  takes `FOR UPDATE` on the ledger row, every debit blocks on its UPDATE, and
  only once all of them wait does the holder commit.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Engram.Rebuild
  alias Engram.Repo

  @debits 8

  setup do
    real_checkout!()
    Repo.query!("DELETE FROM rebuild_ledger")
    on_exit(fn -> real_checkout!() && Repo.query!("DELETE FROM rebuild_ledger") end)
    :ok
  end

  defp real_checkout! do
    case Sandbox.checkout(Repo, sandbox: false) do
      :ok -> true
      {:already, :owner} -> true
    end
  end

  defp lock_waiters do
    %{rows: [[n]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() AND wait_event_type = 'Lock'"
      )

    n
  end

  defp await_lock_waiters(n, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    cond do
      lock_waiters() >= n -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("only #{lock_waiters()} blocked")
      true -> Process.sleep(10) && await_lock_waiters(n, deadline)
    end
  end

  test "concurrent debits never overspend and never lose a token" do
    :ok = Rebuild.set_budget(500)
    test = self()

    holder =
      Task.async(fn ->
        real_checkout!()

        Repo.transaction(fn ->
          Repo.query!("SELECT 1 FROM rebuild_ledger FOR UPDATE")
          send(test, :locked)

          receive do
            :commit -> :ok
          after
            15_000 -> Repo.rollback(:test_timeout)
          end
        end)
      end)

    assert_receive :locked, 5_000

    debits =
      for _ <- 1..@debits do
        Task.async(fn ->
          real_checkout!()
          Rebuild.debit(100)
        end)
      end

    await_lock_waiters(@debits)
    send(holder.pid, :commit)
    assert {:ok, :ok} = Task.await(holder)

    results = Enum.map(debits, &Task.await/1)

    # 500 / 100: exactly five fit, every later one halts.
    assert Enum.frequencies(results) == %{ok: 5, halt: @debits - 5}
    assert Rebuild.ledger() == %{budget_tokens: 500, spent_tokens: 100 * @debits, halted?: true}
  end
end

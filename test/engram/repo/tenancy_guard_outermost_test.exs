defmodule Engram.Repo.TenancyGuardOutermostTest do
  @moduledoc """
  Every other test of the probe runs under `Engram.DataCase`, which checks the
  connection out in sandbox mode — so the test body already sits inside a
  transaction and the probe's `Repo.transaction/2` call is NESTED.

  No production caller has that shape. `TenancyGuard.enforcement/0` is asked
  from `init/1` at boot and from the top of the `OrphanSweep` and
  `CrdtBloatSweep` Oban jobs, all of which are OUTERMOST. There, `mode:
  :savepoint` issues a `SAVEPOINT` with no enclosing `BEGIN`; the transaction
  fails with `DBConnection.TransactionError: transaction is not started`, the
  pooled connection is torn down, and `run_probe/0`'s catch-all maps it to
  `:unknown`.

  That failed silently — `:unknown` is a legitimate verdict, so `combine/2`
  fell back to the attribute answer and nothing logged a defect. The
  behavioural probe never ran in production at all, and burned a connection
  each time it didn't. The shape that ships was the one shape never tested.

  This file therefore checks out with `sandbox: false` on purpose, and writes
  NOTHING. An earlier version of it inserted a user/vault/note so it could
  assert `:bypassed` end to end; outside the sandbox those are real rows, the
  cleanup could not cascade past `notes_user_id_fkey`, and the leftovers broke
  unrelated tests in the same run (a unique-email collision, and a sibling
  assertion that the probe returns `:unknown` on an empty database). A
  non-sandbox test that writes is a contaminator. These assertions need no
  data.
  """
  use ExUnit.Case, async: false

  alias Engram.Repo
  alias Engram.Repo.TenancyGuard

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    :ok
  end

  describe "probe_opts/0" do
    test "asks for no savepoint when outermost — the shape every prod caller has" do
      refute Repo.in_transaction?()
      assert TenancyGuard.probe_opts() == []
    end

    test "still asks for a savepoint when nested, so a caller's work survives" do
      Repo.transaction(fn ->
        assert TenancyGuard.probe_opts() == [mode: :savepoint]
        Repo.rollback(:done)
      end)
    end

    test "the transaction commits in BOTH shapes" do
      # The defect, stated directly. Before the fix the outermost case is
      # `{:error, :rollback}` and takes the pooled connection down with it.
      assert {:ok, :ran} = Repo.transaction(fn -> :ran end, TenancyGuard.probe_opts())

      Repo.transaction(fn ->
        assert {:ok, :ran} = Repo.transaction(fn -> :ran end, TenancyGuard.probe_opts())
        Repo.rollback(:done)
      end)
    end

    test "the probe actually routes through it" do
      # Asserted by source because the behavioural alternative is the
      # contaminating one described in the moduledoc. Without this, `run_probe/0`
      # could keep its hardcoded `mode: :savepoint` and every test above would
      # still pass.
      source = File.read!("lib/engram/repo/tenancy_guard.ex")

      assert source =~ "Engram.Repo.transaction(&probe/0, probe_opts())",
             "run_probe/0 must take its transaction mode from probe_opts/0"

      refute source =~ "transaction(&probe/0, mode: :savepoint)",
             "an unconditional :savepoint means the probe is dead in production again"
    end
  end

  describe "observed_enforcement/0 with no enclosing transaction" do
    test "reaches a real verdict instead of failing the transaction" do
      # On an empty database the honest answer is `:unknown`, so this cannot
      # discriminate on the return value alone — `tenancy_guard_test.exs` owns
      # the verdict semantics, under the sandbox where fixtures are safe.
      #
      # What it does prove is that the call completes without raising and
      # without tearing the connection down: the connection is still usable
      # afterwards, which is false when the savepoint fails.
      assert TenancyGuard.observed_enforcement() in [:enforced, :bypassed, :unknown]
      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    end
  end
end

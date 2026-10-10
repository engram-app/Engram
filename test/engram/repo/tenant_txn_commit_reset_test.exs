defmodule Engram.Repo.TenantTxnCommitResetTest do
  @moduledoc """
  A top-level `Repo.with_tenant/2` skips `tenant_exit`: its COMMIT (or
  ROLLBACK) is the reset. This file is the proof that skipping it is safe.

  Every setting `tenant_enter` makes is `set_config(..., true)` (SET LOCAL),
  so the end of the real transaction reverts both the tenant GUC and the role.
  If either ever became session-scoped, the next checkout of the pooled
  connection would inherit another user's tenant: a cross-tenant leak.

  The sandbox cannot show this. It wraps every test in one transaction, so a
  "top-level" with_tenant there is a savepoint and nothing ever commits (and
  `with_tenant` keeps `tenant_exit` under it for exactly that reason). These
  tests run on a dynamic repo with a REAL pool of size 1, outside the sandbox,
  so "the same connection, checked out again afterwards" is literal: the
  backend pid is asserted, not assumed.

  The suite connects as a superuser, which bypasses RLS, so the reset is
  proven via `current_setting` / `current_user` first; the RLS control
  (`unscoped read sees zero rows`) drops to `engram_app` by hand to make the
  row count mean something (docs/context/rls-enforcement-testing-traps.md).
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Repo

  setup do
    {:ok, probe} =
      Repo.start_link(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 1,
        log: false
      )

    Repo.put_dynamic_repo(probe)

    sources = start_source_capture()

    # The probe is linked to the test process and stops with it.
    on_exit(fn -> :telemetry.detach(sources) end)

    %{tenant: Ecto.UUID.generate()}
  end

  # The session state of the pool's one connection, read outside any
  # transaction: what the NEXT checkout would inherit.
  defp session_state do
    %{rows: [[pid, tenant, current, session]]} =
      Repo.query!(
        "SELECT pg_backend_pid(), current_setting('app.current_tenant', true), " <>
          "current_user::text, session_user::text"
      )

    %{pid: pid, tenant: tenant, current_user: current, session_user: session}
  end

  defp assert_clean(state, pid) do
    assert state.pid == pid, "pool of size 1 handed back a different connection"
    assert state.tenant in [nil, ""], "tenant leaked to the next checkout: #{state.tenant}"

    assert state.current_user == state.session_user,
           "role leaked to the next checkout: #{state.current_user}"
  end

  defp start_source_capture do
    me = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:engram, :repo, :query],
      fn _e, _m, meta, _ -> if self() == me, do: send(me, {:source, meta[:source]}) end,
      nil
    )

    id
  end

  defp drain_sources(acc \\ []) do
    receive do
      {:source, s} -> drain_sources([s | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp inside_state do
    %{rows: [[tenant, current]]} =
      Repo.query!("SELECT current_setting('app.current_tenant', true), current_user::text")

    {tenant, current}
  end

  describe "top-level with_tenant on a real pool" do
    test "commit resets tenant and role; no tenant_exit round trip", %{tenant: t} do
      %{pid: pid} = session_state()
      _ = drain_sources()

      assert {:ok, {^t, "engram_app"}} = Repo.with_tenant(t, &inside_state/0)

      # Exact list: BEGIN, enter, the block's own read (no source), COMMIT.
      # No reset of either flavor.
      assert drain_sources() == ["tenant_txn", "tenant_enter", nil, "tenant_txn"]

      assert_clean(session_state(), pid)
    end

    test "rollback resets tenant and role", %{tenant: t} do
      %{pid: pid} = session_state()

      assert {:error, :refused} =
               Repo.with_tenant(t, fn ->
                 {^t, "engram_app"} = inside_state()
                 Repo.rollback(:refused)
               end)

      assert_clean(session_state(), pid)
    end

    test "a raise inside the block resets tenant and role", %{tenant: t} do
      %{pid: pid} = session_state()

      assert_raise RuntimeError, fn ->
        Repo.with_tenant(t, fn ->
          {^t, "engram_app"} = inside_state()
          raise "boom"
        end)
      end

      assert_clean(session_state(), pid)
    end

    test "a failed statement inside the block resets tenant and role", %{tenant: t} do
      %{pid: pid} = session_state()

      assert_raise Postgrex.Error, fn ->
        Repo.with_tenant(t, fn -> Repo.query!("SELECT 1 / 0") end)
      end

      assert_clean(session_state(), pid)
    end

    test "nested same-tenant call reuses the txn and still resets", %{tenant: t} do
      %{pid: pid} = session_state()
      _ = drain_sources()

      assert {:ok, {:ok, {^t, "engram_app"}}} =
               Repo.with_tenant(t, fn -> Repo.with_tenant(t, &inside_state/0) end)

      assert drain_sources() == ["tenant_txn", "tenant_enter", nil, "tenant_txn"]

      assert_clean(session_state(), pid)
    end
  end

  describe "a pool that is not the known prod pool" do
    # Fail closed: only DBConnection.ConnectionPool is known to give a real
    # BEGIN for a top-level transaction. Any other pool module keeps the reset.
    defmodule UnknownPool do
      @moduledoc false
      @behaviour DBConnection.Pool

      defdelegate child_spec(arg), to: DBConnection.ConnectionPool

      @impl true
      defdelegate checkout(pool, callers, opts), to: DBConnection.ConnectionPool

      @impl true
      defdelegate disconnect_all(pool, interval, opts), to: DBConnection.ConnectionPool

      @impl true
      defdelegate get_connection_metrics(pool), to: DBConnection.ConnectionPool
    end

    test "a top-level block keeps tenant_exit", %{tenant: t} do
      {:ok, probe} =
        Repo.start_link(name: nil, pool: UnknownPool, pool_size: 1, log: false)

      Repo.put_dynamic_repo(probe)
      %{pid: pid} = session_state()
      _ = drain_sources()

      assert {:ok, {^t, "engram_app"}} = Repo.with_tenant(t, &inside_state/0)

      assert drain_sources() == ["tenant_txn", "tenant_enter", nil, "tenant_exit", "tenant_txn"]
      assert_clean(session_state(), pid)
    end
  end

  describe "with_tenant nested in a plain transaction (#1761)" do
    test "the outer txn continues with tenant and role cleared", %{tenant: t} do
      %{pid: pid} = session_state()
      _ = drain_sources()

      assert {:ok, {inner, after_block}} =
               Repo.transaction(fn ->
                 {:ok, inner} = Repo.with_tenant(t, &inside_state/0)
                 {inner, inside_state()}
               end)

      # CONTROL: the tenant really was in force inside the block.
      assert inner == {t, "engram_app"}

      {tenant, role} = after_block
      assert tenant in [nil, ""]
      %{session_user: session} = session_state()
      assert role == session

      assert "tenant_exit" in drain_sources()
      assert_clean(session_state(), pid)
    end
  end

  describe "RLS control" do
    # Real committed rows, so the next checkout can see them. Cleaned up by
    # hand: there is no sandbox to roll them back.
    setup %{tenant: t} do
      vault_id = Ecto.UUID.generate()
      # Before the inserts, so a failure half-way still cleans up.
      on_exit(fn -> cleanup(t) end)

      Repo.insert!(Engram.Factory.build(:user, id: t, email: "tenant-reset-#{t}@test.com"))

      Repo.insert!(%Engram.Vaults.Vault{
        id: vault_id,
        user_id: t,
        slug_hmac: :crypto.strong_rand_bytes(32),
        name_ciphertext: "n",
        name_nonce: :crypto.strong_rand_bytes(12),
        name_hmac: :crypto.strong_rand_bytes(32)
      })

      blank = %Note{}
      note = Engram.Factory.build(:note)
      Repo.insert!(%{note | user: blank.user, vault: blank.vault, user_id: t, vault_id: vault_id})
      :ok
    end

    defp cleanup(t) do
      {:ok, probe} =
        Repo.start_link(name: nil, pool: DBConnection.ConnectionPool, pool_size: 1, log: false)

      Repo.put_dynamic_repo(probe)
      id = Ecto.UUID.dump!(t)

      for table <- ~w(notes vaults users) do
        col = if table == "users", do: "id", else: "user_id"
        Repo.query!("DELETE FROM #{table} WHERE #{col} = $1", [id])
      end

      Supervisor.stop(probe)
    end

    # Count the tenant's notes as `engram_app` with NO tenant set by this
    # transaction: only a leaked tenant GUC can make it non-zero.
    defp count_as_app_role(t) do
      {:ok, n} =
        Repo.transaction(fn ->
          Repo.query!("SELECT set_config('role', 'engram_app', true)")

          Repo.cross_tenant(fn ->
            Repo.aggregate(from(n in Note, where: n.user_id == ^t), :count)
          end)
        end)

      n
    end

    test "an unscoped read after a top-level block sees zero rows", %{tenant: t} do
      %{pid: pid} = session_state()

      # CONTROL: inside the block the policy admits the tenant's row.
      assert {:ok, 1} =
               Repo.with_tenant(t, fn ->
                 Repo.aggregate(from(n in Note, where: n.user_id == ^t), :count)
               end)

      assert count_as_app_role(t) == 0
      assert_clean(session_state(), pid)
    end
  end
end

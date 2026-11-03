defmodule Engram.Repo.TenancyGuardTest do
  @moduledoc """
  The guard's whole job is to report a fact no local config can state: whether
  the credential in `DATABASE_URL` is one RLS applies to. So the load-bearing
  test is the pair — the same function must answer differently for the suite's
  own superuser connection and for a dropped role on that same connection.

  Asserting only the first would pass against `def enforced?, do: false`.

  Since #1726 there are TWO questions, and the pair is asserted for both:

    * `claimed_enforcement/0` — what `pg_roles` says about the role.
    * `observed_enforcement/0` — what the connection can actually see.

  On SaaS prod those disagree, which is the whole reason the second exists.
  A test that only covered the first would still pass on a deployment where
  RLS is not enforced at all.
  """
  # NOT async: one test flips the global `:maintenance_repo_enabled` app env to
  # exercise the resolver. That is only harmless today because
  # `Repo.maintenance/0`'s single caller is the boot guard, which is disabled in
  # test — the moment a `lib/` caller exists, a concurrent test could resolve to
  # a repo that was never started.
  #
  # The role drops below are a second, independent reason: `SET LOCAL SESSION
  # AUTHORIZATION` applies to the connection, so two of these running
  # concurrently on a shared sandbox connection would each see the other's role.
  use Engram.DataCase, async: false

  import Engram.Fixtures

  alias Engram.Repo.TenancyGuard

  # Opted out of the enforced-RLS diagnostic: enforcement is asserted as a
  # PAIR (bypassed for the suite's superuser connection, not-bypassed under a
  # dropped role), and a suite-wide drop would make the first half false.
  @moduletag :rls_unsafe

  describe "observed_enforcement/0" do
    setup do
      {:ok, user} = user_with_dek_fixture()
      vault = insert_vault!(user, "Probe")
      insert_note!(user, vault, %{path: "probe.md", content: "x"})
      :ok
    end

    test "bypassed for the suite's connection, which sees another tenant's rows" do
      # Not an accident of the test harness — it is the reason the RLS bug was
      # invisible for months. dev, CI, and SaaS prod all connect as a superuser,
      # and a superuser bypasses RLS even under FORCE ROW LEVEL SECURITY.
      #
      # Note what this asserts: the probe adopted a tenant that owns nothing and
      # still saw a row. That is a statement about visibility, not about role
      # attributes, and it is the half #1649 could not get from pg_roles.
      assert TenancyGuard.observed_enforcement() == :bypassed
    end

    test "not bypassed under a dropped role, on the same connection" do
      # The discriminating half. A probe that really reads live visibility flips
      # here; a hardcoded answer cannot.
      #
      # SESSION AUTHORIZATION rather than SET ROLE, for the reason
      # `Engram.RlsCase` documents at length: `with_tenant/2` exits via
      # `set_config('role', 'none', true)`, which under SET ROLE hands the
      # connection back to the suite's superuser mid-call.
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")

        refute TenancyGuard.observed_enforcement() == :bypassed

        Repo.rollback(:done)
      end)
    end

    # RLS state is per-table and this repo toggles it per-table: ten
    # migrations issue NO FORCE ROW LEVEL SECURITY and re-FORCE at the end. An
    # interrupted one leaves a single table exposed. One exposed table must be
    # enough. The DDL rolls back with the transaction.
    test "one tenant table with RLS off is enough to report bypassed" do
      {:error, verdict} =
        Repo.transaction(fn ->
          Repo.query!("ALTER TABLE rebuild_manifest_vaults DISABLE ROW LEVEL SECURITY")
          Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
          Repo.rollback(TenancyGuard.observed_enforcement())
        end)

      assert verdict == :bypassed
    end

    # Each failure mode the catalog flags alone cannot see must report
    # bypassed (red on 156c2fd94, whose only check was row_security_active).
    defp as_app(setup_sql) do
      {:error, verdict} =
        Repo.transaction(fn ->
          for sql <- setup_sql, do: Repo.query!(sql)
          Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
          Repo.rollback(TenancyGuard.observed_enforcement())
        end)

      verdict
    end

    test "a permissive USING (true) policy is a bypass" do
      assert as_app([
               "CREATE POLICY leak ON rebuild_manifest_vaults FOR SELECT USING (true)"
             ]) == :bypassed
    end

    test "a table with no tenant policy is a bypass" do
      assert as_app([
               "DROP POLICY tenant_isolation_rebuild_manifest_vaults ON rebuild_manifest_vaults"
             ]) == :bypassed
    end

    test "a tenant policy that does not test the tenant is a bypass" do
      assert as_app([
               "ALTER POLICY tenant_isolation_rebuild_manifest_vaults ON rebuild_manifest_vaults USING (true)"
             ]) == :bypassed
    end

    test "the app credential on the maintenance role is a bypass" do
      {:error, verdict} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_maintenance")
          Repo.rollback(TenancyGuard.observed_enforcement())
        end)

      assert verdict == :bypassed
    end

    test "a USING (true) policy granted to the app role by name is a bypass" do
      user = insert(:user)
      vault = insert(:vault, user: user)
      _ = insert(:note, user: user, vault: vault)

      assert as_app([
               "CREATE POLICY leak2 ON notes FOR SELECT TO engram_app USING (true)"
             ]) == :bypassed
    end

    test "every tenant table is checked, as the RLS-subject role none leaks" do
      {:error, verdict} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
          Repo.rollback(TenancyGuard.observed_enforcement())
        end)

      assert verdict == :unknown
    end

    # Red on c0c603cb9: the probe read every tenant table (under a 250 ms
    # timeout that counted as "no leak" and leaked into the caller). It now
    # reads tenant tables only through user_id indexes and sets no timeout.
    test "the probe reads a tenant table only by user_id and sets no timeout" do
      {_, queries} =
        Engram.QueryRecorder.record(fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
            Repo.rollback(TenancyGuard.observed_enforcement())
          end)
        end)

      sqls = for %{pid: pid, sql: sql} <- queries, pid == self(), do: sql
      refute Enum.any?(sqls, &(&1 =~ "statement_timeout"))

      for table <- Engram.Repo.tenant_tables(),
          sql <- sqls,
          sql =~ ~s(FROM "#{table}"),
          do:
            assert(sql =~ ~s("user_id" = ANY), "#{table} read without the user_id bound: #{sql}")
    end

    # Red on 5be4a3373: tables whose only user_id-leading index is partial
    # (chunk_points, crdt_update_log, note_index_state) were probed and
    # seq-scanned. Every probe statement, EXPLAINed as the app role under a
    # tenant that owns nothing, with its real parameters, uses an index.
    test "every probe read of a tenant table is an index read for the app role" do
      _ = insert(:user)

      {_, queries} =
        Engram.QueryRecorder.record(fn ->
          Repo.transaction(fn ->
            Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
            Repo.rollback(TenancyGuard.observed_enforcement())
          end)
        end)

      reads =
        for %{pid: pid, sql: sql, params: params} <- queries,
            pid == self(),
            Enum.any?(Engram.Repo.tenant_tables(), &(sql =~ ~s(FROM "#{&1}"))),
            do: {sql, params}

      assert length(reads) > 5

      {:error, plans} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
          Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [Ecto.UUID.generate()])
          Repo.query!("SET LOCAL enable_seqscan = off")

          Repo.rollback(
            for {sql, params} <- reads,
                do:
                  {sql,
                   Repo.query!("EXPLAIN " <> sql, params).rows
                   |> List.flatten()
                   |> Enum.join("\n")}
          )
        end)

      for {sql, plan} <- plans, do: refute(plan =~ "Seq Scan", "#{sql}\n#{plan}")

      {probed, catalog_only} = TenancyGuard.probe_tables()
      assert "chunk_points" in catalog_only
      refute "chunk_points" in probed
    end

    test "a tenant policy widened with OR true is a bypass" do
      assert as_app([
               "ALTER POLICY tenant_isolation_rebuild_manifest_vaults ON rebuild_manifest_vaults USING (user_id = (SELECT NULLIF(current_setting('app.current_tenant', true), '')::uuid) OR true)"
             ]) == :bypassed
    end

    test "a permissive WITH CHECK (true) is a bypass" do
      assert as_app([
               "ALTER POLICY tenant_isolation_rebuild_manifest_vaults ON rebuild_manifest_vaults WITH CHECK (true)"
             ]) == :bypassed
    end

    test "leaves the caller's tenant untouched" do
      # The guard borrows a pooled connection that goes straight back into
      # service, and it sets `app.current_tenant` to do its work. If that leaked
      # it would silently re-scope whatever ran next on the same connection —
      # the leak-forward trap in rls-enforcement-testing-traps.md, except in
      # lib/ rather than in a test.
      Repo.transaction(fn ->
        Repo.query!("SELECT set_config('app.current_tenant', $1, true)", [
          "11111111-1111-1111-1111-111111111111"
        ])

        TenancyGuard.observed_enforcement()

        assert %{rows: [["11111111-1111-1111-1111-111111111111"]]} =
                 Repo.query!("SELECT current_setting('app.current_tenant', true)")

        Repo.rollback(:done)
      end)
    end
  end

  describe "enforcement/0 combines both signals, asymmetrically" do
    # No fixtures in this describe block on purpose: with every tenant table
    # empty the probe returns :unknown, which is one of the conditions here.

    test "uses the attribute answer when the probe cannot speak" do
      # A fresh self-host install has no rows yet. The catalog answers for the
      # suite's superuser whatever the rows (row security is not active for
      # it), and the combined answer stays :bypassed, so OrphanSweep runs on a
      # database with nothing to sweep instead of refusing forever.
      assert TenancyGuard.observed_enforcement() == :bypassed
      assert TenancyGuard.enforcement() == :bypassed
    end

    test "prod's shape — probe says bypassed, attributes say enforced — resolves CAUTIOUS" do
      # The safety property, and the reason this is not `observed || claimed`.
      # `enforced?/0` gates irreversible Qdrant point and S3 prefix deletion in
      # OrphanSweep. Prod refuses every run today because the attribute answer
      # is :enforced; letting the probe alone flip that to :bypassed would
      # start those deletions as a side effect of improving a diagnostic, on a
      # signal whose mechanism #1726 says nobody has identified.
      assert TenancyGuard.combine(:bypassed, :enforced) == :enforced
      assert TenancyGuard.combine(:enforced, :bypassed) == :enforced
    end

    test ":unknown abstains rather than vetoing" do
      # The bug caught while writing this: treating :unknown as a veto made
      # OrphanSweep refuse on every empty database — every fresh self-host
      # install, and four of its own tests.
      assert TenancyGuard.combine(:unknown, :bypassed) == :bypassed
      assert TenancyGuard.combine(:bypassed, :unknown) == :bypassed
      assert TenancyGuard.combine(:unknown, :enforced) == :enforced
      assert TenancyGuard.combine(:enforced, :unknown) == :enforced
    end

    test "agreement passes straight through, and total silence is :unknown" do
      assert TenancyGuard.combine(:bypassed, :bypassed) == :bypassed
      assert TenancyGuard.combine(:enforced, :enforced) == :enforced
      assert TenancyGuard.combine(:unknown, :unknown) == :unknown
    end
  end

  describe "claimed_enforcement/0" do
    test "enforced for a role with neither rolsuper nor rolbypassrls" do
      # Kept, and kept as a pair, because the DIVERGENCE is the finding. This
      # is the question the guard used to answer, and on prod it answers
      # :enforced while observed_enforcement/0 has historically disagreed.
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL ROLE engram_app")
        assert TenancyGuard.claimed_enforcement() == :enforced
        Repo.rollback(:done)
      end)
    end

    test "bypassed for the suite's superuser connection" do
      assert TenancyGuard.claimed_enforcement() == :bypassed
    end
  end

  describe "enforced?/0" do
    setup do
      {:ok, user} = user_with_dek_fixture()
      vault = insert_vault!(user, "Probe")
      insert_note!(user, vault, %{path: "probe.md", content: "x"})
      :ok
    end

    test "false for the suite's connection" do
      refute TenancyGuard.enforced?()
    end

    test "true under a dropped role" do
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL SESSION AUTHORIZATION engram_app")
        assert TenancyGuard.enforced?()
        Repo.rollback(:done)
      end)
    end
  end

  describe "Engram.Repo.maintenance/0" do
    test "resolves to Engram.Repo when no second credential is configured" do
      # The self-host shape, and the default: callers read the same whether or
      # not a maintenance pool exists.
      assert Repo.maintenance() == Engram.Repo
    end

    test "resolves to the maintenance pool once enabled" do
      Application.put_env(:engram, :maintenance_repo_enabled, true)
      on_exit(fn -> Application.delete_env(:engram, :maintenance_repo_enabled) end)

      assert Repo.maintenance() == Engram.Repo.Maintenance
    end

    test "the maintenance pool does NOT enforce the tenant tripwire" do
      # `Engram.Repo.prepare_query/3` is what makes ~235 call sites carry
      # `skip_tenant_check: true`. The maintenance pool exists to run exactly
      # the queries that guard rejects, so enforcing it there would make the
      # pool useless and push every caller back to the keyword option this
      # change is trying to retire.
      #
      # Driven through the callback directly — it is a pure function of the
      # query and the process dict, so this needs no second pool and no
      # connection.
      #
      # NOT checked with `function_exported?/3`: `use Ecto.Repo` injects a
      # default `prepare_query/3`, so BOTH modules export it and only one
      # overrides it. The structural check cannot see the difference and passes
      # either way.
      query = Ecto.Queryable.to_query(Engram.Notes.Note)

      assert_raise Engram.TenantError, fn ->
        Engram.Repo.prepare_query(:all, query, [])
      end

      assert {^query, []} = Engram.Repo.Maintenance.prepare_query(:all, query, [])
    end
  end
end

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

  describe "verdict/2" do
    # Pure, so the interesting cases can be stated directly. Two of them — an
    # empty table and a never-analyzed one — are awkward to manufacture inside
    # a sandbox that has just seeded fixtures, and they are precisely the cases
    # where a naive implementation reports a clean bill of health it did not
    # earn.

    test "a visible row is decisive, whatever the table size estimate" do
      assert TenancyGuard.verdict(true, 5000.0) == :bypassed
      assert TenancyGuard.verdict(true, 0.0) == :bypassed
      assert TenancyGuard.verdict(true, -1.0) == :bypassed
    end

    test "no visible row against a populated table means enforced" do
      assert TenancyGuard.verdict(false, 3602.0) == :enforced
    end

    test "no visible row against an EMPTY table proves nothing" do
      # The trap this guard exists to avoid. An enforced connection and a
      # bypassed one are indistinguishable on an empty table, so the only
      # honest answer is :unknown.
      assert TenancyGuard.verdict(false, 0.0) == :unknown
    end

    test "no visible row against a NEVER-ANALYZED table proves nothing" do
      # Postgres reports reltuples = -1, not 0, for a table that has never been
      # analyzed. Treating that as "0 rows, therefore enforced" would be a
      # false green on every freshly-restored database.
      assert TenancyGuard.verdict(false, -1.0) == :unknown
    end
  end

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

  describe "enforcement/0 falls back when the probe cannot speak" do
    # No fixtures in this describe block on purpose: with no notes row the
    # probe returns :unknown, which is exactly the condition under test.

    test "uses the attribute answer rather than reporting :unknown" do
      # A fresh self-host install has no notes yet. Reporting :unknown there
      # would make `enforced?/0` true, which makes OrphanSweep refuse its
      # weekly run forever and log an error about it each time — on a database
      # with nothing to sweep.
      #
      # This also pins that the probe's strictness did not silently become the
      # global default: four orphan_sweep tests caught exactly this regression
      # before the fallback existed.
      assert TenancyGuard.observed_enforcement() == :unknown
      assert TenancyGuard.enforcement() == :bypassed
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

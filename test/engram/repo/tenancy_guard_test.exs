defmodule Engram.Repo.TenancyGuardTest do
  @moduledoc """
  The guard's whole job is to report a fact no local config can state: whether
  the credential in `DATABASE_URL` is one RLS applies to. So the load-bearing
  test is the pair — the same function must answer differently for the suite's
  own superuser connection and for a dropped role on that same connection.

  Asserting only the first would pass against `def enforced?, do: false`.
  """
  # NOT async: one test flips the global `:maintenance_repo_enabled` app env to
  # exercise the resolver. That is only harmless today because
  # `Repo.maintenance/0`'s single caller is the boot guard, which is disabled in
  # test — the moment a `lib/` caller exists, a concurrent test could resolve to
  # a repo that was never started.
  use Engram.DataCase, async: false

  alias Engram.Repo.TenancyGuard

  describe "enforced?/0" do
    test "false for the suite's connection, which bypasses RLS" do
      # Not an accident of the test harness — it is the reason the RLS bug was
      # invisible for months. dev, CI, and SaaS prod all connect as a superuser,
      # and a superuser bypasses RLS even under FORCE ROW LEVEL SECURITY.
      refute TenancyGuard.enforced?()
    end

    test "true under a dropped role, on the same connection" do
      # The discriminating half. `SET LOCAL ROLE` changes `current_user`, so a
      # probe that really reads the live role flips here, and a hardcoded
      # answer cannot.
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL ROLE engram_app")
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

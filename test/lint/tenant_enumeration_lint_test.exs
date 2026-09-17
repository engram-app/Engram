defmodule Engram.TenantEnumerationLintTest do
  @moduledoc """
  Grep-style lint: a query that **enumerates tenants** (groups or selects on
  `user_id`) against a tenant-scoped schema must NOT pass
  `skip_tenant_check: true`.

  That combination is the #1349 shape. It reads zero rows on prod:
  `skip_tenant_check` only bypasses Engram's application-level guard in
  `Engram.Repo.prepare_query/3` — it never sets `app.current_tenant` — and the
  tenant policy's `current_setting('app.current_tenant', true)` is then NULL,
  so `FORCE ROW LEVEL SECURITY` filters every row for a role without
  BYPASSRLS. The query succeeds, returns `[]`, and the backfill reports
  "nothing to do" on a database full of work.

  Dev and CI cannot catch this at runtime: `Repo.with_tenant/2` drops to the
  `engram_app` role precisely because the local superuser bypasses RLS
  regardless of FORCE, so the broken shape passes every test. Hence a source
  lint.

  Deny-by-default on purpose. Five backfills carried this shape; three were
  fixed in the first pass of #1349 and the other two were missed *because the
  guard was a hand-written list of modules*. A lint derived from the code
  cannot be out of date the way that list was.

  Narrow by design — `skip_tenant_check: true` is used ~280 times across
  `lib/`, almost all of them legitimate single-row or non-tenant reads. Only
  the enumerate-every-tenant shape is a bug, so only that is flagged. Sibling
  of `raw_sql_tenant_table_lint_test.exs`, which covers the raw-SQL route to
  the same place.
  """
  use ExUnit.Case, async: true

  @lib_dir Path.expand("../../lib", __DIR__)

  # Files allowed to enumerate tenants with the guard skipped. Each entry needs
  # a comment explaining why RLS cannot filter it.
  @allowlist []

  # The schema list used to be hardcoded here, and the moduledoc below argues
  # at length that a hand-written list of MODULES is what let two #1349
  # backfills slip through. It then went stale in exactly that way: it said
  # `UserAgreement` (the module is `Onboarding.Agreement`) and omitted `Action`,
  # `VaultIndexState` and `VaultIndexUpdateLog` — 4 of 11 tables unguarded.
  # It hid no live offender, so nothing failed to tell us.
  #
  # Derived from `Repo.tenant_tables/0` instead, by finding which module
  # declares `schema "<table>"`. The completeness assertion is the load-bearing
  # half: without it, a renamed schema module silently shrinks the guard, which
  # is the same failure wearing a different hat.
  test "every tenant table resolves to exactly one schema module" do
    # Hoisted: called inside the predicate, this re-scanned every source file
    # in lib/ once per tenant table.
    by_table = schema_basenames_by_table()

    {resolved, missing} =
      Engram.Repo.tenant_tables()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.split_with(&(by_table[&1] != nil))

    assert missing == [], """
    #{length(missing)} of #{length(resolved) + length(missing)} tenant tables have no
    `schema "<table>"` declaration in lib/, so the enumeration lint below is
    blind to them:

    #{Enum.map_join(missing, "\n", &"  #{&1}")}

    Either the table was renamed, or its schema moved. Fix the mapping — do not
    delete the table from `Repo.tenant_tables/0` to make this pass.
    """
  end

  test "no query enumerates tenants on a tenant table with skip_tenant_check" do
    # Filtered to the tenant tables, NOT every schema in lib/. Taking all of
    # `schema_basenames_by_table/0` here made the lint flag
    # `from(rt in RefreshToken)` — `refresh_tokens` has no RLS policy, so that
    # query is fine and the report was noise. A lint that cries wolf about
    # non-tenant tables is worse than the stale list it replaced.
    by_table = schema_basenames_by_table()

    schemas =
      Engram.Repo.tenant_tables()
      |> Enum.map(&by_table[Atom.to_string(&1)])
      |> Enum.reject(&is_nil/1)

    offenders =
      @lib_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&scan(&1, schemas))
      |> Enum.reject(fn {file, _line, _snippet} -> file in @allowlist end)

    assert offenders == [], """
    A tenant-enumerating query is skipping the tenant guard. On prod this
    returns ZERO rows under FORCE ROW LEVEL SECURITY and silently no-ops
    (#1349). Route the discovery through `Engram.Backfill.TenantScan`, or
    allowlist the file with a justification.

    #{Enum.map_join(offenders, "\n", fn {f, l, s} -> "  #{f}:#{l}\n    #{s}" end)}
    """
  end

  defp scan(path, schemas) do
    rel = Path.relative_to(path, @lib_dir)
    src = File.read!(path)

    ~r/from\(.{0,900}?skip_tenant_check:\s*true/s
    |> Regex.scan(src, return: :index)
    |> Enum.flat_map(fn [{start, len}] ->
      block = binary_part(src, start, len)

      if enumerates_tenants?(block) and tenant_schema?(block, schemas) do
        line = src |> binary_part(0, start) |> String.split("\n") |> length()
        [{rel, line, block |> String.split("\n") |> List.first()}]
      else
        []
      end
    end)
  end

  defp enumerates_tenants?(block),
    do: Regex.match?(~r/(group_by|select):\s*\[?[^\n]*\.user_id/, block)

  defp tenant_schema?(block, schemas),
    do: Regex.match?(~r/\bfrom\(\s*\w+\s+in\s+(#{Enum.join(schemas, "|")})\b/, block)

  # table name => schema module basename, read from source.
  #
  # Basename only, because the lint matches `from(x in Note)` — source text,
  # where the alias is what appears, not the fully-qualified module.
  #
  # Ceiling: a file declaring two schemas maps both tables to its first
  # `defmodule`. No tenant table is shaped that way today, and the
  # completeness test above is what notices if that stops being true.
  defp schema_basenames_by_table do
    @lib_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      src = File.read!(path)

      case Regex.run(~r/^defmodule\s+([\w.]+)/m, src) do
        [_, module] ->
          basename = module |> String.split(".") |> List.last()

          ~r/^\s*schema\s+"(\w+)"/m
          |> Regex.scan(src)
          |> Enum.map(fn [_, table] -> {table, basename} end)

        nil ->
          []
      end
    end)
    |> Map.new()
  end
end

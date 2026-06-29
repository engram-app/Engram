defmodule Engram.RawSqlTenantTableLintTest do
  @moduledoc """
  Grep-style lint: raw SQL (`Repo.query`, `Repo.query!`, or
  `Ecto.Adapters.SQL.query[!]`) must NOT reference a tenant-scoped table.

  The app DB connection runs as a role for which RLS is FORCE-enabled, but the
  ORM safety net (`Engram.Repo.prepare_query/3`, which refuses to run a query
  on a tenant table unless `with_tenant` set `app.current_tenant`) only sees
  *structured* `Ecto.Query` ASTs. A raw SQL string bypasses that net entirely,
  so a tenant-table query issued outside `with_tenant` would run unscoped.

  Tenant tables are sourced directly from `Engram.Repo.tenant_tables/0`, so this
  lint can't drift from the actual guarded set.

  If you must run raw SQL touching a tenant table (e.g. an operator backfill
  that is intentionally cross-tenant), add the file to @allowlist with a
  justification — same discipline as the notes-scope lint.
  """
  use ExUnit.Case, async: true

  alias Engram.Test.SourceLint

  @lib_dir Path.expand("../../lib", __DIR__)

  @tenant_tables Enum.map(Engram.Repo.tenant_tables(), &Atom.to_string/1)

  # Files allowed to run raw SQL against a tenant table. Each entry needs a
  # comment explaining WHY the cross-tenant raw query is legitimate.
  @allowlist [
    # Operator-run, intentionally cross-tenant backfill: seeds
    # onboarding_actions for every legacy user by scanning `FROM vaults`.
    # Runs as a one-shot Mix task / release command, never on a request path.
    "mix/tasks/engram.backfill_onboarding_actions.ex",
    # Vaults.next_seq!/1 — atomic `UPDATE vaults SET change_seq = change_seq + 1
    # ... RETURNING change_seq` for the sync change-log seq allocator. MUST be
    # called inside the caller's existing `Repo.with_tenant/2` transaction (see
    # the @doc), so it DOES run under RLS tenant context — the raw SQL is needed
    # for the single-round-trip read-modify-write + row lock, not to bypass RLS.
    "engram/vaults.ex"
  ]

  # Matches a raw-SQL call and the text immediately following it (covers
  # multi-line heredoc SQL where the table name sits a few lines below the
  # `Repo.query!(` call).
  @raw_sql_call ~r/(?:Repo\.query!?|Ecto\.Adapters\.SQL\.query!?)\(.{0,600}/s

  test "no raw SQL references a tenant table outside the allowlist" do
    offenders =
      @lib_dir
      |> SourceLint.walk_ex_files()
      |> Enum.reject(fn path ->
        rel = Path.relative_to(path, @lib_dir)
        Enum.any?(@allowlist, &String.ends_with?(rel, &1))
      end)
      |> Enum.flat_map(&scan_file/1)

    assert offenders == [],
           "Raw SQL on a tenant table bypasses the RLS safety net. " <>
             "Route it through with_tenant + a structured Ecto.Query, or " <>
             "allowlist the file with a justification.\n\n" <>
             Enum.map_join(offenders, "\n\n", fn {file, table, snippet} ->
               "#{file} → table `#{table}`:\n#{snippet}"
             end)
  end

  defp scan_file(path) do
    content = File.read!(path)
    rel = Path.relative_to(path, @lib_dir)

    @raw_sql_call
    |> Regex.scan(content)
    |> Enum.flat_map(fn [block] ->
      Enum.flat_map(@tenant_tables, fn table ->
        # `(FROM|INTO|UPDATE|JOIN|TABLE) <table>` — the SQL keyword anchor
        # avoids matching the table name where it appears as an unrelated
        # substring (e.g. a column or a parameter name).
        if Regex.match?(~r/\b(?:FROM|INTO|UPDATE|JOIN|TABLE)\s+#{table}\b/i, block) do
          [{rel, table, String.slice(block, 0, 160)}]
        else
          []
        end
      end)
    end)
  end
end

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

  # Schema modules backed by a table in `Engram.Repo.tenant_tables/0`. Matched
  # by module basename because the lint reads source, not AST.
  @tenant_schemas ~w(Note Attachment Vault ApiKey UserAgreement CrdtUpdateLog NoteLink Chunk)

  # Files allowed to enumerate tenants with the guard skipped. Each entry needs
  # a comment explaining why RLS cannot filter it.
  @allowlist []

  test "no query enumerates tenants on a tenant table with skip_tenant_check" do
    offenders =
      @lib_dir
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.flat_map(&scan/1)
      |> Enum.reject(fn {file, _line, _snippet} -> file in @allowlist end)

    assert offenders == [], """
    A tenant-enumerating query is skipping the tenant guard. On prod this
    returns ZERO rows under FORCE ROW LEVEL SECURITY and silently no-ops
    (#1349). Route the discovery through `Engram.Backfill.TenantScan`, or
    allowlist the file with a justification.

    #{Enum.map_join(offenders, "\n", fn {f, l, s} -> "  #{f}:#{l}\n    #{s}" end)}
    """
  end

  defp scan(path) do
    rel = Path.relative_to(path, @lib_dir)
    src = File.read!(path)

    ~r/from\(.{0,900}?skip_tenant_check:\s*true/s
    |> Regex.scan(src, return: :index)
    |> Enum.flat_map(fn [{start, len}] ->
      block = binary_part(src, start, len)

      if enumerates_tenants?(block) and tenant_schema?(block) do
        line = src |> binary_part(0, start) |> String.split("\n") |> length()
        [{rel, line, block |> String.split("\n") |> List.first()}]
      else
        []
      end
    end)
  end

  defp enumerates_tenants?(block),
    do: Regex.match?(~r/(group_by|select):\s*\[?[^\n]*\.user_id/, block)

  defp tenant_schema?(block),
    do: Regex.match?(~r/\bfrom\(\s*\w+\s+in\s+(#{Enum.join(@tenant_schemas, "|")})\b/, block)
end

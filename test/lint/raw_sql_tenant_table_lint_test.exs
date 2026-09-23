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
    # (engram/onboarding/backfill.ex was allowlisted here as "intentionally
    # cross-tenant". That was the bug, not the exception: a cross-tenant raw
    # SELECT against a FORCE-RLS table reads zero rows on prod. #1349 made it
    # tenant-scoped, which let it become a structured Ecto insert — so it needs
    # no exemption at all. If you are about to add an entry justified by
    # "intentionally cross-tenant", read
    # docs/context/migrations-force-rls-data-dml.md first.)
    # Vaults.next_seq!/1 — atomic `UPDATE vaults SET change_seq = change_seq + 1
    # ... RETURNING change_seq` for the sync change-log seq allocator. MUST be
    # called inside the caller's existing `Repo.with_tenant/2` transaction (see
    # the @doc), so it DOES run under RLS tenant context — the raw SQL is needed
    # for the single-round-trip read-modify-write + row lock, not to bypass RLS.
    "engram/vaults.ex",
    # Attachments.batch_soft_delete_rows/3 — the batch-delete seq-block bump
    # (next_seq!'s idiom with `+ $2`) and the multi-row `UPDATE ... FROM
    # (VALUES ...)` soft delete where every row gets a DISTINCT seq — a shape
    # `update_all` cannot express. Both statements run inside the enclosing
    # `Repo.with_tenant/2` transaction, so RLS tenant context is active.
    "engram/attachments.ex",
    # Notes.bulk_rename_update!/4 — the folder-rename cascade's batched
    # `UPDATE notes ... FROM (VALUES ...)`: each row carries distinct
    # re-encrypted ciphertexts (per-row values, one statement). Runs inside
    # do_rename_folder's `Repo.with_tenant/2` transaction — RLS context active.
    "engram/notes.ex",
    # TenancyGuard.observed_enforcement/0 — `SELECT EXISTS (SELECT 1 FROM notes
    # LIMIT 1)` under a tenant that owns nothing.
    #
    # This is the one entry NOT justified by "runs inside with_tenant", and it
    # is deliberately not the anti-pattern the comment at the top of this list
    # warns about. That warning is about code which reads cross-tenant, gets
    # zero rows on prod, and believes it worked. Here zero rows is the EXPECTED
    # result and the assertion: the guard is measuring whether the policy
    # filters, so routing it through the ORM safety net would make it measure
    # the safety net instead of the database.
    #
    # `skip_tenant_check: true` on a structured query would be the wrong shape
    # for the same reason — the probe is not skipping a tenant check, it is
    # setting a tenant and observing what the server does about it.
    #
    # Bounded by LIMIT 1, inside a savepoint, and it restores the caller's
    # tenant before returning.
    "engram/repo/tenancy_guard.ex"
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

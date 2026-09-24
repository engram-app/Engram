defmodule Engram.RawSqlTenantTableLintTest do
  @moduledoc """
  Grep-style lint: raw SQL — ANY `.query/.query!` call, whatever the receiver
  is spelled as — must NOT reference a tenant-scoped table.

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
    # CrdtBloatSweep.measure/0 — one whole-table aggregate over `notes`
    # computing size percentiles for the history/trash epic (#1706). Genuinely
    # cross-tenant by design: the question is "how much is CRDT state costing
    # us in total", which has no tenant.
    #
    # Reaches Postgres through `Repo.maintenance()`, so it takes the exempt
    # pool wherever one is configured.
    #
    # It does NOT have the lying-oracle problem an auditor might expect here:
    # `tenancy_unsafe?/0` refuses with `{:error, :tenancy_unsafe}` when
    # `Repo.maintenance() == Repo and TenancyGuard.enforced?()`, and the
    # worker's own "Why it refuses rather than reporting zero" section explains
    # why. On prod today that condition holds — no MAINTENANCE_DATABASE_URL,
    # and the attribute signal reads :enforced — so this query does not run at
    # all rather than returning a fabricated zero. Unblocking it is Phase 2
    # (#1649), not this lint.
    "engram/workers/crdt_bloat_sweep.ex"
  ]

  # Matches ANY `.query(` / `.query!(` receiver, not a list of spellings.
  #
  # The previous pattern named the receivers it expected (`Repo.query`,
  # `Ecto.Adapters.SQL.query`) and every unnamed spelling was invisible:
  # `Repo.maintenance().query!(` slipped through and put a `FROM notes`
  # aggregate in `crdt_bloat_sweep.ex`, flagged by nobody. Enumerating shapes
  # is a losing game — `repo.query!(` with a repo passed as a variable appears
  # ten times in `lib/engram/release.ex` alone, and `Maintenance.query!(` via
  # an alias contains no "repo" at all.
  #
  # Being this broad is safe because an offence needs BOTH a `.query(` call and
  # a tenant table named in a FROM/JOIN/INTO/UPDATE clause within the window.
  # Verified: across all of `lib/`, this produces zero offenders outside the
  # allowlist — the same four files the narrow pattern found.
  #
  # The window is 2000 characters because 600 did not reach the table name of a
  # long aggregate: in `crdt_bloat_sweep.ex` the gap between the call and
  # `FROM notes n` is 1418 characters, so even once the call matched, the table
  # was invisible. Both holes had to be fixed; the first attempt at this closed
  # only the call shape, and the lint still passed against the very file that
  # prompted it.
  #
  # NON-CONSUMING lookahead, which is load-bearing. `Regex.scan/2` returns
  # non-overlapping matches, so a greedy consuming `.{0,2000}` swallows any
  # call starting inside its window — and that call's table name, sitting past
  # the window end, is then scanned by nobody. Widening a consuming window
  # trades one false-negative class for another.
  @raw_sql_call ~r/\.query!?\((?=(.{0,2000}))/s

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

  describe "@raw_sql_call" do
    # The sweep above cannot pin this. Every offender it would have found is
    # now allowlisted, so it passes identically against the OLD narrow pattern
    # — which is exactly the failure this file was rewritten about: a lint that
    # stayed green against the very file that prompted it. Without these, a
    # future "simplify the regex" reopens both holes and CI says nothing.

    test "matches a receiver it was never told about" do
      # Enumerating spellings is what let `Repo.maintenance().query!(` through.
      for call <- [
            "Repo.query!(",
            "Repo.query(",
            "Repo.maintenance().query!(",
            # A repo passed as a variable — ten of these in release.ex.
            "repo.query!(",
            # The module `Repo.maintenance()` resolves to once
            # MAINTENANCE_DATABASE_URL is set. Contains no "repo" at all.
            "Maintenance.query!(",
            "Engram.Repo.Maintenance.query!(",
            "Ecto.Adapters.SQL.query!("
          ] do
        assert Regex.match?(@raw_sql_call, call <> "\"SELECT 1 FROM notes\""),
               "#{call} evades the lint"
      end
    end

    test "the window reaches past a long statement preamble" do
      # 600 characters did not reach `FROM notes n` in crdt_bloat_sweep.ex,
      # measured at 1418 characters past the call.
      sql =
        "Repo.query!(\"\"\"\nSELECT\n" <> String.duplicate("  count(*),\n", 130) <> "FROM notes n"

      assert byte_size(sql) > 1418, "fixture must exceed the gap it stands in for"
      assert [[_, window]] = Regex.scan(@raw_sql_call, sql)
      assert window =~ "FROM notes"
    end

    test "one call does not swallow the next" do
      # The lookahead is load-bearing. A greedy CONSUMING window makes
      # Regex.scan skip any call starting inside it, so the swallowed call's
      # table name — past the window end — is scanned by nobody. Widening a
      # consuming window just moves the false negative.
      clean = "Repo.query!(\"SELECT 1\")\n" <> String.duplicate("# filler\n", 200)
      dirty = "Repo.query!(\"SELECT * FROM chunks\")"

      windows = Regex.scan(@raw_sql_call, clean <> dirty) |> Enum.map(fn [_, w] -> w end)

      assert Enum.any?(windows, &(&1 =~ "FROM chunks")),
             "the second call was swallowed by the first call's window"
    end
  end

  defp scan_file(path) do
    content = File.read!(path)
    rel = Path.relative_to(path, @lib_dir)

    @raw_sql_call
    |> Regex.scan(content)
    # `[_match, block]` — the window is a lookahead CAPTURE, not the match
    # itself, so the match is only the `.query(` token. That is what makes the
    # scan non-overlapping on a 1-character footprint instead of a 2000-char
    # one, and therefore what stops one call from swallowing the next.
    |> Enum.flat_map(fn [_match, block] ->
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

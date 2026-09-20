# The `skip_tenant_check` audit

**Read this if** you are about to add `skip_tenant_check: true`, you are
wondering whether a background job is silently doing nothing, or a sweep
reports success while the data says otherwise.

Audited 2026-09-17 against `5dcdcdc3`. 271 textual occurrences in `lib/`; 235
real call sites; 36 are prose.

Re-audited 2026-09-19 against `63e74adb`: **bucket D is empty.** Of the 32
sites, 30 were deleted outright as their callers were restructured, and 2 (the
`links.ex` prefetch reads) are scoped in place. Bucket C's *classification*
still holds, but none of its six sites carry `skip_tenant_check` any more —
they moved to `Repo.cross_tenant/1`, which is a renamed bypass, not a scope.
The `lib/` population fell 271 → 237, so every count below is as-of-2026-09-17
and no longer current.

## What the option does, and does not do

`skip_tenant_check: true` suppresses `Engram.Repo.prepare_query/3` — an
*application-level* tripwire — and nothing else. It sets no Postgres session
state. It is not a tenant scope, and it never was.

Where RLS is enforced, a query carrying it with no enclosing
`Repo.with_tenant/2` is filtered by the tenant policy:

| operation | what happens | loud? |
|---|---|---|
| `SELECT` | returns zero rows | no |
| `UPDATE` | reports 0 affected | no |
| `DELETE` | reports 0 affected | no |
| `INSERT` | raises SQLSTATE 42501 | yes |

Three of four are silent. That asymmetry is the whole reason this class of bug
survived: the loud one is rare, and the quiet ones are indistinguishable from
"there was no work to do."

"Where RLS is enforced" is a property of the credential, not the schema. The
tables have carried `FORCE ROW LEVEL SECURITY` and a correct policy for months,
but a superuser bypasses RLS even under FORCE — and dev and CI both connect as
one. Staging-fastraid **and self-host** connect as `engram_app`, which is why
staging broke and dev/CI did not.

**Whether SaaS prod enforces is UNRESOLVED, and the evidence conflicts.** Do
not repeat either answer as settled. `Engram.Repo.TenancyGuard` reports which
side a given deployment is on, at boot.

Prod connects as `engram_admin` — `rolsuper = false`, `rolbypassrls = false`.
What is on record, and why it does not add up:

- **#1649 read prod directly.** Tenant verifiably set, `notes` carrying
  `relrowsecurity` AND `relforcerowsecurity`, and `select count(*) from notes`
  returned **all 3,602 rows**. That says NOT enforced.
- **#1354 / #1357 record the opposite**, also against prod: a tenant-table
  query outside `with_tenant` returning zero rows. If the role simply ignored
  RLS, that read would have returned everything.
- `OrphanSweep` running rather than refusing also points at not-enforced.

Both prod observations cannot hold unless something not yet identified
conditions them. Nobody has isolated what.

**One hypothesis is already dead, so do not re-derive it.** #1649 proposed
`pg_read_all_data` / `pg_write_all_data` membership as the mechanism. Tested on
staging 2026-09-19 against `notes` (FORCE RLS, 5,411 rows, no tenant set): a
role holding `pg_read_all_data` and one without it BOTH saw **0 rows**. It does
not defeat FORCE RLS, exactly as the PostgreSQL docs say. The remaining
candidate from `engram_admin`'s membership list is `rds_superuser`, which
cannot be reproduced on FastRaid because FastRaid is not RDS.

Settling this needs one read against prod. See also
`lib/engram/accounts.ex:798-822`.

## The four buckets

| bucket | count | meaning |
|---|---|---|
| A — non-tenant table | 159 | touches only `users`, `subscriptions`, `oauth_*`, `usage_meters`, … RLS does not apply. Harmless noise. |
| B — already scoped | 38 | inside a `with_tenant`, often via a closure run by a caller. Correct. |
| C — cross-tenant by design | 6 | genuinely spans tenants, or is *discovering* the tenant. Needs the maintenance pool. |
| D — unscoped, looks wrong | 32 | a tenant is in scope but unused. Probable live bugs where RLS is on. |

`@tenant_tables` (`lib/engram/repo.ex`) is the authority for which tables count:
`notes chunks attachments api_keys vaults user_agreements onboarding_actions
crdt_update_log note_links vault_index_states vault_index_update_log`.

## Bucket C — the legitimate cross-tenant sites

These cannot use `with_tenant`, because there is no single tenant to set. All
six have since moved from `skip_tenant_check: true` to `Repo.cross_tenant/1`,
which at least names itself a bypass — it sets no Postgres state either:

- `accounts.ex` — `api_keys` lookup by `key_hash`. The user_id is the thing
  being discovered; scoping it would require knowing the answer first.
- `indexing.ex` ×2 — `flag_notes_for_rebuild/1`. The contract has since
  INVERTED: callers must now already be inside `Repo.with_tenant/2`
  (`indexing.ex:437`), and its caller `ReindexKeyword` is a single-tenant
  per-vault job, not a cross-user sweep.
- `notes.ex` — the legacy `fetch_note_for_worker/1` bridge, for jobs enqueued
  before `user_id` travelled in job args.
- `orphan_sweep.ex` ×2 — whole-collection Qdrant↔`chunks` reconciliation. RLS
  would hide exactly the rows that prove a point is still live.

## Bucket D — the debt list (all discharged)

Discharged as of 2026-09-19: 30 of the 32 sites were deleted outright as their
callers were restructured, and 2 are scoped in place. Kept as a record of the
class, because the next batch will look the same: every entry below was live
only where RLS is enforced, and all but one of them failed SILENTLY.

The last to land was `links.ex` ×2, and it outlived the rest for the reason
worth remembering — it was reached correctly from one caller and unscoped from
five, so it read as fine in isolation.

Ordered by consequence, worst first. Counts are as-of-audit, not current.

| site | consequence under RLS, before the fix |
|---|---|
| `crypto/rotation_lock.ex` | count reads 0 → `half_state_pending?` false → **stale-lock takeover proceeds when it must be refused**. The moduledoc calls the result irreversible S3 blob corruption. |
| `workers/cleanup_vault.ex` ×6 | vault never found, or notes/chunks/attachments never deleted and storage keys never collected → hard delete silently does nothing, blobs orphaned. |
| `crypto/aad_rebind.ex` ×5 | rebind sees no legacy rows → reports `:skipped` forever; one site raises `MatchError` on `{1, _} =`. |
| `accounts/lifecycle.ex` | vaults survive → the subsequent `Repo.delete!(user)` hits an FK violation → every hard delete returns `{:error, :pg_failed}`. |
| `auth/device_flow.ex` | `{:error, :vault_not_found}` → device-link authorize always fails. |
| `oauth.ex` | length mismatch → every vault-scoped OAuth grant refused with `access_denied`. |
| `links/rewriter.ex` ×3 | `{:error, :target_gone}` → rename link-rewriting never runs. |
| `links.ex` ×2 | link resolution finds no candidates. Reached unscoped via `replace_links/4`'s prefetch, which runs *before* that function's `with_tenant`. |
| `accounts/export.ex` ×2 | sum reads 0 → the export size cap **fails open**. |
| `accounts/export/streamer.ex` ×2 | export contains no vaults and no notes, still marked `:ready`. |
| `vaults.ex` ×3 | vault names, note counts and attachment counts all read empty/0. |
| `notes.ex` | `vault_populated` never broadcast → the FTUX page spins forever. |
| `accounts.ex` | `purge_user_vaults/1` enqueues nothing. (`crypto/aad_rebind.ex` was listed here as well, double-counting its ×5 row above — which is why this table enumerates 33 sites under a header that says 32. The real total is 32.) |
| `keyword_index/stats.ex` | nil → silent fallback to `@default_avgdl` → wrong BM25 weights. |
| `workers/reindex_keyword.ex` | flags nothing → an operator-triggered re-index is a silent no-op. |
| `workers/vault_deleted_email.ex` | nil vault → returns `:ok`, deletion notice never sent. |

Two of these had **no tenant in scope at all** and could not be fixed by
wrapping alone: `keyword_index/stats.ex` and `workers/reindex_keyword.ex`.
Both now thread a `user_id` in from their caller, the way `EmbedNote` does,
and then wrap — so the fix this audit said was owed is the fix that shipped.

Two were **mixed-path** — scoped on one caller, not another — which is why
they read as correct in isolation and were the hardest to see:

- `links.ex`: the candidate prefetch in `replace_links/4` ran *before* that
  function opened its own `with_tenant`. Filtered, it returned no candidates
  and every wikilink edge was written DANGLING — silently, because the
  `insert_all` downstream *was* scoped and succeeded. `BackfillNoteLinks`
  reached it scoped; FIVE paths did not — `commit_index/1`,
  `index_note_with_usage/3`'s `:no_chunks` branch, `ExtractNoteLinks`,
  `Rewriter.finish/4`, and `Rewriter.rewrite_legacy/5` (via `attempt/6`'s
  `{:legacy, _}` branch, after `load_doc/2`'s block has closed). Now scoped
  inside `prefetch_candidates/4` itself, which is why the count of callers
  does not matter to the fix — only to this description, which said "four"
  until a review caught the fifth.
- `crypto/aad_rebind.ex`: scoped only when called from `BackfillCrdtState`.
  Now scoped in `do_rebind/1` (`aad_rebind.ex:99`). NOT at `rebind_note/2`,
  which still requires its caller's tenant by documented contract.

## Why there is no "is it scoped?" lint

Because that is not a lexical property. `crypto/user_dek_rotation.ex` has 21
sites inside closures that `sweep_table_loop/4` executes inside a
`with_tenant`, nowhere near them in the source. Any lint that reads call sites
flags all 21 and gets switched off within a week.

So the mechanism is a **count ratchet** instead
(`test/lint/skip_tenant_check_inventory_test.exs`): per-file counts must match a
reviewed inventory, and adding a site fails until someone updates the number.
It judges nothing about correctness. It only stops the population growing
quietly, so this audit does not go stale.

Its sibling `tenant_enumeration_lint_test.exs` *does* judge, and pays for it in
coverage: it matches only the `from(...)` enumerate-by-`user_id` shape, so it
sees none of the 144 direct `Repo.update` / `Repo.all` / `Repo.get` sites — all
40 `Repo.update` calls among them, which are the silent shape. Both tests stay.

## What to do instead of adding a site

If the query spans tenants, use `Engram.Repo.maintenance()`. The *pool you
reach for* then declares cross-tenant intent, and that shows up in a diff; a
keyword at the end of a long query does not.

Know what it resolves to, though. `maintenance()` is only a separate, exempt
pool when `MAINTENANCE_DATABASE_URL` is set. When it is unset — which is the
case in prod today — it resolves to `Engram.Repo` itself
(`lib/engram/repo/maintenance.ex:33`), tripwire and all. So it documents intent
everywhere, but it only *grants* an exemption where that variable is set.

If a single tenant is available, wrap it in `Repo.with_tenant/2`. That was the
fix for every bucket-D site that still exists. Most of the 32 did not need it
in the end — they were deleted outright as their callers were restructured —
and the two with no tenant in scope needed a `user_id` threaded in from their
caller first, then the same wrap.

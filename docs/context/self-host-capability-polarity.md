# Self-host must grant everything: boolean limit-key polarity

_Last verified: 2026-08-31_

## Status

FIXED — backend PR #1439 (`fix/one-limits-source`), plugin PR #457. The rule
below is now enforced by a test, not by discipline.

## The symptom

A self-hosted instance silently dropped **every image and PDF** on first sync.
319 notes uploaded, 0 attachments, and the client reported success. No error,
no `POST /api/attachments` in the server log — the plugin never asked. The
server would have accepted all of them (`Storage.S3.put/2` verified working,
`text_only?(user)` returned `false`).

Reported by the user as "why did non-md files break".

## The mechanism

`Billing.effective_limit/2` returns `:unlimited` for every key when
enforcement is off (self-host). `compute_capabilities/1` then normalizes:

```elixir
defp normalize_capability(:boolean, :unlimited), do: true   # "enforcement off opens the gate"
```

That is correct for a **grant-shaped** boolean (`true` == the user gets the
thing). `attachments_text_only` was **restriction-shaped** (`true` == denied)
— the only inverted boolean in the catalog. So for that one key, turning
enforcement OFF turned the restriction ON.

The plugin pre-gates attachments on that value
(`preGateAttachment` → `plan.attachmentsTextOnly`) and skips them **client
side with no network call**, which is why the server logs were silent.

## The rule

**Every boolean in `LimitKeys` must be grant-shaped: `true` means the user
gets the thing.** Never encode a restriction as `true`, even when it reads
naturally ("text only", "warn at 60 days"). `:unlimited` maps to `true`
generically, so an inverted key inverts the meaning of "no limits".

Enforced by `limit_keys_test.exs`:

```elixir
refute free == true and pro == false,
       "#{key} is inverted (free=true, pro=false): `true` must mean granted"
```

That test found a SECOND inverted key nobody had noticed —
`inactivity_warn_60_days` — under which self-hosted instances sent free-tier
inactivity dunning about the operator's own data. Both were renamed:

| was (restriction-shaped) | now (grant-shaped) |
|---|---|
| `attachments_text_only` free=true | `attachments_all_types` free=false |
| `inactivity_warn_60_days` free=true | `inactivity_warnings_exempt` free=false |

## Renaming a limit key: what breaks

Not just call sites. A key is an identifier in four places:

1. **DB** — `user_limit_overrides.key` rows carry the old string.
2. **Env** — `env_var_names/0` DERIVES `ENGRAM_<TIER>_<KEY>` from the catalog,
   so dropping a key silently stops parsing its env var. No boot error.
3. **Plan rows** — `plans.limits` JSONB keyed by the old string.
4. **The `@unenforced` list** in `test/engram/billing/limit_enforcement_test.exs`.

**There is no longer a safety net for (1).** `@legacy_inverted_keys` in
`billing.ex` used to resolve the old spellings across (1)-(3) and flip the
sense; it was deleted in the pricing-v2 contract step (engram#1535) once the
shims it protected had no one left to protect. A rename now goes straight to
the failure it guarded: a surviving `user_limit_overrides` row is never
SELECTed, the user falls to the catalog default, and because the default is
the permissive value the restriction is silently LIFTED. Nothing alerts.

**So a rename needs a data migration in the same PR.** See
`priv/repo/migrations/20260831120000_translate_legacy_limit_overrides_migrate_data.exs`
for the shape: INSERT the translated row (negating `value->>'v'` when the
polarity inverts), `ON CONFLICT DO NOTHING` so an existing row under the new
spelling wins, then DELETE the old. Reads never re-validate an override row and
`UserLimitOverride.changeset/2` rejects retired keys, so the migration is the
only place the repair can happen.

Point (2) has no safety net either and never did: `plan_overrides` is a PULL
model iterating `env_var_names/0`, so an env var whose key left the catalog is
simply never read. `EnvLimits.parse!/3` validates the VALUE, never the NAME —
its "fail-fast boot crash" promise holds only for a malformed value on a key
that still exists.

## Fail direction is per-key, and it is a decision

Booleans fail CLOSED on an unreadable value (`normalize_capability(:boolean, _)
-> false`). Overrides are operator-written JSON, so a string `"false"` instead
of the boolean is reachable without a code change. Writing the helper as
`effective_limit(...) != false` is fail-OPEN and hands a Free user the paid
surface — a real defect caught in review of #1439, not in production.

But fail-closed is not universal. `inactivity_warnings_exempt?/1` deliberately
inverts it: refusing the attachments grant costs an upload, while refusing THIS
grant mails someone about inactivity and starts the deletion clock. On a value
we cannot read, leave the user alone. **State the direction in the helper's
doc; do not leave it implicit.**

## The trap that made this expensive to find

Three call sites each re-derived the same answer and they DISAGREED:

| call site | enforcement off |
|---|---|
| `plan_state/1` (what the plugin reads) | `false` ✓ |
| `attachments_controller.text_only?` | `false` ✓ |
| `capabilities/1` (what the web app reads) | **`true`** ✗ |

Two of the three were right, which is why "check the server" looked fine.
`Billing.attachments_all_types?/1` is now the single answer for the two direct
callers; `capabilities/1` still resolves generically, so a **test** pins the
two paths to agree across every tier. Nothing in the type system binds them.

## Diagnosis recipe

Server-side, against the running instance (Tidewave `project_eval`):

```elixir
%{
  billing_enabled: Application.get_env(:engram, :billing_enabled),
  limits_enforced: Application.get_env(:engram, :limits_enforced, true),
  raw:  Billing.effective_limit(user, :attachments_all_types),
  caps: Billing.capabilities(user).limits["attachments_all_types"],
  plan: Billing.plan_state(user).attachments_all_types
}
```

If `raw` is `:unlimited` but `caps` is a restriction, the polarity rule is
broken again. `billing_enabled` and `limits_enforced` are derived from the
identical expression (`auth_provider == :clerk and PADDLE_API_KEY != nil`),
so they should never disagree; `:self_host` is configured nowhere and read by
nothing.

Client-side, the tell is **silence**: a plan-gated attachment produces no HTTP
request at all, and parks an *informational* issue in Sync Center rather than
an error. `resyncSkippedAttachments()` (Sync Center action) bypasses the
pre-gate and re-uploads whatever is parked.

## Related gotchas from the same wave (2026-08-20)

- **`openapi.json` is committed and drift-gated.** Removing a route leaves it
  stale and fails the `unit-tests` job (not the test suite — a separate step).
  Regenerate with `MIX_ENV=test mix openapi.spec.json --spec EngramWeb.ApiSpec
  --pretty=true openapi.json`. The **dev** env has no `ENCRYPTION_MASTER_KEY`,
  so the task aborts on boot and writes nothing while looking like it ran.
- **`frontend/e2e/` is a separate caller surface from `frontend/src/`.** A
  sweep for API callers scoped to `src/` misses Playwright `global-setup.ts`
  and the `*.spec.ts` helpers, which 404 at global setup and take down the
  whole `e2e-browser` job. Grep `frontend/`, not `frontend/src/`.
- **Sobelow skips are line-sensitive.** Adding a comment to a scanned file
  re-fingerprints its findings (`phash2([check, source, file, line])`).
  Verify the finding COUNT is unchanged, then
  `rm -f .sobelow-skips && mix sobelow --mark-skip-all`. Full detail in
  `sobelow-silent-no-op-and-fingerprint-skips.md`.
- **`EntitlementCache` is `NodeLocalEts`** with an 86,400,000ms TTL, which
  would be long enough to serve pre-rename key names. It does not survive a
  deploy (the BEAM restarts), so a key rename needs no cache migration.

## References

- `lib/engram/billing/limit_keys.ex` — the catalog and the polarity comment
- `lib/engram/billing.ex` — `attachments_all_types?/1`,
  `inactivity_warnings_exempt?/1` (`@legacy_inverted_keys` removed in #1535)
- `test/engram/billing/limit_keys_test.exs` — the no-inverted-boolean invariant
- Plugin `src/plan-state.ts`, `src/auth-state.ts` (`CLEARED_AUTH_VALUES`) —
  the plan is a per-backend verdict and is dropped when the server changes

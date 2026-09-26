# An MCP-first signup completes OAuth, then 403s `onboarding_required` forever

_Last verified: 2026-09-25_

## Status

**Fixed** by engram-app/Engram#1670 (open, not yet merged as of 2026-09-16). Two prod
accounts were confirmed dead-ended before the fix, both abandoned; neither has been
contacted. Related: [[onboarding-gate-is-http-only]], [[mcp-oauth]],
[[connections-client-identity]], [[mcp-bypasses-path-shaped-plugs]].

The fix has five parts: an actionable `resume_url` in the 403 body; a JSON-RPC
envelope so MCP clients can actually read that body; a consent-page detour through
the wizard that parks and then resumes the authorization; the tool question
pre-answered from the connecting client; and a `lifecycle` log line plus a Loki rule
(engram-infra#1184) so a recurrence is visible instead of silent for five hours.

## What this is

A user who reaches Engram **through an MCP client's OAuth flow** — never through
app.engram.page — signs up, completes the grant, receives valid refresh tokens, and
then every single MCP tool call returns `403 {"error":"onboarding_required"}`. Forever.
Nothing in the OAuth grant path runs onboarding or links the user to the wizard, and
the MCP client surfaces the 403 as an opaque tool failure. The user has no path
forward and no message telling them one exists.

This is not the channel-gate gap ([[onboarding-gate-is-http-only]], where the gate
failed to run). Here the gate runs, correctly, and there is simply no way for the user
to satisfy it from where they are standing.

## The prod case (2026-09-15)

User `dgonzalez.integraenergia@gmail.com`, id `01a0a550-4d17-795b-88ea-92d5e4d8e62a`,
Clerk `user_3JMne9wsT1Pxy6hHMpo3FCQAbyr`. All times UTC.

| Time | What happened |
|---|---|
| 13:44:42 | DCR registers client `052a941b-6db6-4ee5-b7d8-b5df6ab6e7dc`, name **"Google Antigravity"**, redirect `https://antigravity.google/oauth-callback` |
| 13:44:58 | `users` row created — **the signup happened inside the OAuth grant flow** |
| 13:45:18 | Grant succeeds: 2 `oauth_refresh_tokens`, scope `mcp`, expiring 2026-12-14 |
| 13:45:18 | The client's first 4 MCP tool calls all `POST 403`, verdict `onboarding_required`, `missing: ["profile","subscription","terms","vault"]` |
| 13:49:55 → 19:25:32 | 12 more DCR registrations named `antigravity-client`, interleaved with 41 `auth rejected reason=no_auth` 401s. No further refresh tokens ever issued. User gave up. |

Final DB state for that user: **0** vaults, notes, chunks, attachments,
`crdt_update_log`, api_keys, client_logs, `user_agreements`, `onboarding_actions`,
subscriptions. `plan_id` NULL, `free_tier_accepted_at` NULL, `onboarding_profile` `{}`.
Account not deleted, not suspended. A paying-intent user who produced zero rows.

Same shape, earlier: `aortizsm@gmail.com` (2026-09-11) — 0 agreements, 0 vaults,
0 notes. Contrast a healthy user (`sabio@web.de`): 2 agreements, 1 vault, 100 notes.
**"0 agreements + 0 vaults + a live refresh token" is the query signature of this
class.**

## Why

`POST /api/mcp` pipes `:authed_api` (`router.ex:49-68`), which includes
`plug EngramWeb.Plugs.RequireOnboarding` at `router.ex:55`. That pipeline is shared
with the vault-scoped REST scope on purpose ("a new security control can't be added to
one and silently missed on the other") — so MCP inherits the onboarding gate by
design, and correctly.

The other half of the contract is missing. Nothing in the OAuth path —
`oauth_authorize_controller.ex`, `oauth_token_controller.ex`,
`oauth_register_controller.ex` — mentions onboarding at all (grep them; there are no
hits). The grant is issued to an account that cannot use it, and the only surface
that could tell the user is the MCP client's error rendering, which shows nothing
actionable.

**The device-auth flow already solved this for the plugin** — `DeviceAuthController`
declares its own relaxed gate (`device_auth_controller.ex:21`):

```elixir
plug EngramWeb.Plugs.RequireOnboarding, [skip_vault: true] when action in [:authorize]
```

with a moduledoc explaining the reasoning: fail at the moment the user clicks
"connect", not later with a silent refusal, and skip the vault rule because that
endpoint is what *creates* the first vault. The MCP-first path never got the
equivalent treatment. Any fix belongs in that shape: decide at grant time, and make
the refusal legible.

## Gotchas (prod investigation)

- **Prod Loki ships warning-and-above only** for `{env="prod", role="web"}`.
  Successful 2xx requests are invisible. Never conclude "the user did nothing" from
  log absence — **the DB is the authoritative record** of what a user accomplished.
- **`request_path` is `[REDACTED]`** in prod logs and `route` was null for these
  lines, so you cannot identify the endpoint from the log line. Correlate by
  `user_id` plus DB timestamps instead.
- **`engram_audit_ro` is RLS-bound, and RLS returns zeros rather than errors.** A
  correlated subquery inside a scan over `users`:

  ```sql
  select u.email, (select count(*) from user_agreements a where a.user_id = u.id) ...
  from users u
  ```

  silently returns `0` for **every** row unless `app.current_tenant` is set to that
  specific user. It does not error. **Query one tenant at a time**, or you will
  "discover" that nobody in prod ever accepted the terms.
- The `missing` list is version-dependent. On `main`, `derive_gate/3` computes
  `vault_required = profile_ok and profile["uses_obsidian"] != true`, so an
  incomplete profile can *omit* `"vault"` from the list. Read the list as "the gate
  refused", not as a stable four-element set.
- `antigravity` is already a valid `@valid_tools` slug in `Engram.Onboarding` — the
  product knows about this client; only the entry path is missing.

## If you change this again

Two traps, both found in review *after* the fix looked correct and CI was green.

**Ask `gate_ok`, never `next_step`.** Runtime permission and wizard navigation are
deliberately decoupled, and they **disagree** for obsidian-path users: `derive_gate/3`
admits them (`vault_required` is false when `uses_obsidian=true`) while `next_step/5`
pins them at `:vault` until the plugin's first sync creates a vault. The first cut of
the consent page gated on `next_step !== "done"`, so it bounced exactly those users
consent → wizard → consent, forever — a brand new dead end of the same class this doc
exists to describe, introduced by its own fix. `Onboarding.status/1` now publishes
`gate_ok`, computed by the same `gate_missing/1` that `gate/2` enforces with, so the
wire answer and the enforced answer cannot drift. Never re-derive the gate rule
client-side.

**The step chain describes intent, not progress.** `build_steps/2` drops `:tools` only
when `tools_prefilled` marks it as answered by the OAuth client *before* the wizard
began. An earlier cut keyed the drop on "the profile has tools", which meant an
ordinary signup's own answer deleted the step from their own chain mid-wizard:
self-host rendered "Step 1 of 2" and then "Step 1 of 1", never advancing. `steps` feeds
a "Step X of N" header, so it has to stay stable across the walk.

A third, smaller one: the `engram:pending-oauth` stash is sessionStorage and therefore
survives sign-out. It is cleared in `useClearQueryCacheOnUserChange` alongside the
query cache, because otherwise user A can park an authorization, sign out from the
wizard header, and user B finishes the wizard onto A's consent screen carrying A's
`state` and `redirect_uri`.

## Same dead end on `/link` (plugin-first signups, 2026-09-25)

#1670 only fixed `/oauth/consent`. A plugin-first signup hit the identical wall on
`/link` (`DeviceLinkPage`): in prod on 2026-09-25 a new user clicked Sync 11 times,
each `POST /auth/device/authorize` returned 403 `onboarding_required` (the
`RequireOnboarding` plug on `device_auth_controller.ex` `:authorize`), and the page
rendered the raw string `onboarding_required`, because `ApiError` carries only
`body.error`, not `message` / `resume_url`. Surfaced by the Grafana alert
`engram-prod-loki-onboarding-refused`.

**Root cause:** `/link` and `/oauth/consent` both sit OUTSIDE `OnboardingGate` in
`frontend/src/router.tsx`, on purpose. So every page placed outside the gate must do
its own `gate_ok` bounce.

**Fix:** `stashPendingDeviceLink(code)` in `frontend/src/oauth/pending-authorization.ts`
reuses the same sessionStorage stash; `isResumablePath` now allows `/link`;
`DeviceLinkPage` bounces to `/onboard` when `gate_ok === false`, and auto-verify waits
for the onboarding status to load. The wizard's `onboardingDoneTarget()` then returns
the user to `/link?code=...`.

**Rule:** any new route added outside `OnboardingGate` needs the same bounce, or it
recreates this bug.

## How the audit was run

Read-only bastion, per `engram-infra/docs/context/prod-db-readonly-access.md` (memory
note `project_prod_db_readonly_bastion`): bastion `i-04243b8cd5dec622e`, port-forward
to `localhost:25432`, psql via
`docker run --rm -i --network host postgres:18-alpine`.

## References

- `lib/engram_web/router.ex:49-68` — `:authed_api`, shared by REST + MCP scopes
- `lib/engram_web/router.ex:605-640` — the `/api/mcp` scope
- `lib/engram_web/plugs/require_onboarding.ex` — 403 shaping over `Onboarding.gate/2`
- `lib/engram/onboarding.ex` — `gate/2` / `derive_gate/3`, `@valid_tools`, and the
  shared `gate_missing/1` behind both `gate/2` and `status/1`'s `gate_ok`
- `lib/engram_web/plugs/mcp_error_envelope.ex` — JSON-RPC shaping of pipeline refusals,
  keyed on status rather than plug identity
- `frontend/src/oauth/pending-authorization.ts` — the parked-authorization stash
- `frontend/e2e/oauth-consent-onboarding.spec.ts` — the only browser test that reaches
  an un-onboarded user through the consent path
- engram-infra `main/envs/prod/grafana_alerts.tf` — the `onboarding-refused` Loki rule
- `lib/engram_web/controllers/device_auth_controller.ex:8-21` — the existing
  precedent for relaxing this gate on an entry-point route
- Issue #364 — "extend signup wizard with plugin-connect + first-sync steps" (the
  wizard-side half of the same problem)

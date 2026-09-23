# PostHog instrumentation — the traps that cost real time

_Last verified: 2026-09-17. Shipped on branch `docs/posthog-funnel-plan`._

Read this before touching anything under `frontend/src/analytics/`,
`Engram.Observability.PostHog`, or the `/ph` proxy — and **definitely** before
bumping `posthog-js`.

## 1. The SDK adds its own properties, after your validator runs

`frontend/src/analytics/track.ts` validates every property against a per-event
key schema. That validator **cannot see** what posthog-js attaches afterwards.

posthog-js attaches `$current_url`, `$host`, `$pathname`, `$referrer`,
`$referring_domain`, `$session_entry_*`, `$initial_*` and
`$prev_pageview_pathname` to **every** capture. This is its generic page-info
builder — **`autocapture: false` does not disable it.**

Vault routes are `/v/:slug`, and slug is `slugify(vault_name)`
(`lib/engram/vaults.ex:220`). So without a sanitizer, **vault names leave the
browser inside the URL** on any event fired from a vault page.

This shipped past six reviews. Every one checked the properties we pass; none
checked what reached the wire.

> **Any test for this must assert on post-SDK-merge shape** — what actually
> reaches `posthog.capture` — not on the object the app hands to `track()`. A
> test of the latter kind passes while the leak is wide open.

The strip lives in `frontend/src/analytics/init.ts` via `sanitize_properties`.

### `sanitize_properties` is deprecated — this control fails OPEN

In `posthog-js@1.429.1` it is deprecated. **A future major removes it, the strip
silently stops, and nothing fails.** The test mocks `posthog` wholesale, so it
cannot catch the regression either.

`before_send` is the replacement. Migrate before the next major bump, and when
you do, add a test that does not mock the SDK away.

Two known gaps in the current strip, both closeable in a line each:
- the value fallback matches only absolute `http(s)://`, so a future SDK key
  holding a **relative** path with an unmatched name evades it (adding "drop
  strings starting with `/`" closes it and strips nothing we send);
- nested objects are not recursed (`$web_vitals_*_event`, `$exception_list`) —
  both PostHog remote-config gated, so unreachable today.

## 2. An allowlist over VALUES is not an allowlist over DATA

The first validator accepted any string matching a UUID or equal to one of ~20
enum literals, under any key. So `{ title: "done" }`, `{ folder: "card" }` and
`{ vault_name: "vault" }` all passed — real user content, because the content
happened to equal an enum member.

The key carries the meaning; the value is author-controlled. Validate per event,
per key: `EVENT_SCHEMAS` declares which keys an event permits and each key's
kind, and an undeclared key is rejected whatever its value.

## 3. `run_worker_first` decides whether the Worker runs at all

`frontend/wrangler.jsonc`'s `assets.run_worker_first` lists the only paths that
invoke the Worker; everything else is served as a static asset directly. Add a
route handler without adding its path there and it is **dead code whose only
symptom is a feature silently not working.**

## 4. Self-host must emit nothing, and `--mode` will not save you

`Dockerfile:42-46` exists so self-host bundles never carry the SaaS token, and
the image builds `build:selfhost`. **Never pass `VITE_POSTHOG_KEY` to a Docker
build.**

Vite's env passthrough is **independent of `--mode`**, so a shell with
`VITE_POSTHOG_KEY` set would bake it into a self-host bundle regardless. The
`build:selfhost` script therefore clears the vars explicitly
(`frontend/package.json`). Do not remove that.

Grep the built bundle for `phc_` to prove it. Do **not** grep for
`us.i.posthog.com` — that string is in the self-host bundle on `main` already
as posthog-js's own vendored default-host constant, so it is a false positive.

## 5. Request logs record errors, not traffic

`emit_request_log/2` derives its level from the response status and only `warn`+
ships to Loki. **A user with no log lines had no errors — it does not mean they
made no requests.** Do not read an empty log as an idle user.

## 6. Two identifier schemes exist in the logs

Request logs carry a **raw `users.id` uuid**; plugin remote logs and telemetry
carry an **HMAC** of it (`Engram.Crypto.HMAC.hash_user_id/1`, keyed by
`:hmac_key_user_id`). You cannot compute the hash locally.

`users.id` is uuidv7, so its first 8 hex chars are the signup millisecond —
derive the prefix from a Clerk `created_at` and grep for that. For hashed ids,
correlate by time window; prod is quiet enough that a signup window holds
exactly one new id.

## 7. `hmac_key_analytics_id` must never rotate

It is the stable pseudonymous identity behind every PostHog person. Rotating it
re-identifies the entire user base and orphans all history. It is deliberately
exempt from rotation sweeps — see `engram-infra/docs/context/sops-operator-guide.md`.

If it is unset while `POSTHOG_KEY` is set, `runtime.exs` falls back to a random
per-boot key and now logs a warning. Before that warning existed, this would
have silently re-identified everyone on every deploy.

## 8. Inventory suites fail because things were ADDED

`Engram.EnvVarDocsTest` requires a doc row for every env var `runtime.exs`
reads. The openapi stale-spec gate, the `skip_tenant_check` inventory and the
legal-manifest check all have the same shape.

A task can be purely additive and still break them — "additive" describes the
diff, but the risk lives in the suite. **If a task adds an env var, a route, a
schema field, or a config key, run the full suite**, not just its own tests.

## 9. Published legal versions are immutable

`docs/context/terms-reacceptance-mechanism.md:62` — a correction is a NEW
version file, never an edit to an existing one, and a DB guard rejects a mutated
`content_hash`. Editing `privacy-<date>.md` in place also drifts four copies
across two repos plus a cross-repo CI check, and breaks `build:selfhost`'s
`check-legal-manifest.ts`.

## References

- `engram-workspace/docs/context/user-churn-audit-2026-09-17.md` — the audit that motivated all of this.
- `engram-workspace/docs/context/cookie-audit-2026-05-24.md` — the no-banner decision and the init options that are load-bearing for it.

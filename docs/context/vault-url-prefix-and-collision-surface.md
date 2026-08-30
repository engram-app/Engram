# Vault URLs live under `/v/` — and the full slug-collision surface

**Trigger:** you are adding a top-level route, a `Plug.Static` mount, a Phoenix
scope, or a Cloudflare rule — and want to know whether it can collide with a
vault name. Or you found `@reserved_slugs` referenced somewhere and it no
longer exists.

## The shape

Vault-scoped SPA URLs, and nothing dynamic at the URL root:

| URL | serves |
|---|---|
| `/v` | vault picker (`VaultRedirect`) |
| `/v/:slug` | vault dashboard |
| `/v/:slug/:id` | note or attachment |
| `/v/:slug/wiki/*` | wikilink resolver (targets contain slashes) |

Built in one place on the frontend:

```ts
// frontend/src/routes.ts
export const VAULT_PREFIX = "/v";
export function vaultPath(slug: string, itemId?: string): string
export function noteHref(slug: string | null | undefined, noteId: string): string
export function vaultRootHref(slug: string | null | undefined): string
```

Backend counterpart at the bottom of `lib/engram_web/router.ex`: four `get`s
mirroring exactly those shapes.

**The route list is bounded on purpose, not greedy.** A single
`get "/v/*path"` is tempting and wrong: it makes `/v/work/n-1/extra` a 200 SPA
shell that renders an in-app 404, so a broken deep link looks healthy to an
uptime monitor and is indexable as a soft-404 -- the same
HTTP-200-masking-a-broken-request class the deleted deny-list existed to
prevent, one level down. Keep Phoenix's list matching the React subtree; the
parity test below enforces it in both directions.

## Why the prefix exists

Vault slugs are `slugify(user-supplied vault name)`. While they lived at the
root as `/:slug`, every top-level segment was ambiguous in both directions:

- a vault named "Link" or "Settings" was shadowed by the static SPA route of
  the same name, and
- a typo'd `/api/notez` matched `/:slug/:id` and returned an HTML 200 that
  masked a broken API call (that one is issue #858).

The mitigation was an 18-entry reserved-slug list, hand-mirrored in Elixir
(`Vault.@reserved_slugs`) and TypeScript (`api/reserved-slugs.ts`), folded
into `unique_slug/3` so a colliding name silently became `link-2`.

**It worked, and it was still wrong**, because nothing derived the list from
the actual routers. Every new top-level route silently widened the hazard, and
the list had already drifted — see below.

## The surface the reserved list MISSED

`slugify/1` strips non-word characters and maps whitespace to `-`, so
`"WP Admin"` → `wp-admin` and `"Vendor"` → `vendor`. The Cloudflare **zone**
firewall (`engram-infra/main/cloudflare/security.tf`, `kind = "zone"`, so it
covers `app.engram.page`) blocks these paths outright:

```
/.env  /.git/  /wp-admin  /wp-login  /wp-content  /wp-includes
/phpmyadmin  /phpinfo  /server-status  /cgi-bin  /vendor
```

None of those nine slugify-reachable names were in the reserved list. A user
who named a vault "Vendor" got a **Cloudflare block page**, not a 404 and not
a renamed slug — a failure mode neither list nor deny-list could see, because
it happened one hop before Phoenix. Fixed for free by the prefix: `/v/vendor`
matches no `starts_with` rule.

The `ends_with` rules (`.sql`, `.bak`, `.backup`, `.old`, `.log`) are not
reachable **through the slug** -- `slugify` strips the dot. They ARE reachable
through the **wiki-target** segment, which is a different thing and was wrong
in the first version of this doc:

`frontend/src/viewer/wiki-link.ts` builds `${vaultPath(slug)}/wiki/${encoded}`
where `encoded` is `encodeURIComponent` applied per path segment, and
`encodeURIComponent` leaves `.` alone. So an unresolved `[[server.log]]`
produces `/v/work/wiki/server.log`, and `[[dump.sql]]`, `[[notes.bak]]`,
`[[db.backup]]`, `[[archive.old]]` likewise. Client-side navigation never
touches the edge, so this is invisible in dev and in the unit suite; refresh,
paste, or share that URL on a `*.engram.page` host and Cloudflare answers 403
instead of the create-note affordance.

Not introduced by the prefix move -- old `/work/wiki/server.log` ended the same
way.

**FIXED 2026-08-30** in engram-infra#1088 (`2dc0aa48`). The extension clause in
`main/cloudflare/security.tf` now carves out the wikilink resolver, requiring
BOTH `/v/` and `/wiki/`:

```
(ends_with(path, ".sql") or ... or ends_with(path, ".log"))
and not (starts_with(path, "/v/") and path contains "/wiki/")
```

`/v/work/other.log` (no `/wiki/`), `/backup.log` and `/vendor/db.sql` all stay
blocked -- note the trailing slash in `"/v/"` means `/vendor/...` does not match
the carve-out. Nothing is weakened at the web root, which is what that rule is
for.

Two alternatives were rejected. Percent-encoding the dot does not work:
Cloudflare URL normalization decodes `%2E` before rules run. Moving the target
into a query string (`/v/:slug/wiki?t=server.log`) would work, since the query
is not part of `http.request.uri.path`, but it is a second URL migration for a
defect this narrow.

## The deny-list went too

The first version of this doc argued the router deny-list
(`match :*, "/api/*path", SpaController, :not_found` and 10 siblings) should
stay, because it returned "a clean non-HTML 404 instead of Phoenix's default
HTML error page". **That rationale was false and the deny-list is now
deleted.** Measured, not reasoned:

| request | with deny-list | without |
|---|---|---|
| `/api/notez`, `Accept: application/json` | **406** `Phoenix.NotAcceptableError` | `404` `{"errors":{"detail":"Not Found"}}` |
| `/api/notez`, no `Accept` | `404` `text/plain "Not Found"` | `404` `{"errors":{"detail":"Not Found"}}` |
| `/assets/missing.js` | `404` `text/plain` | `404` `application/json` |

Two things were wrong with the original reasoning. There is no HTML error
renderer in this app: `config/config.exs` registers only
`render_errors: [formats: [json: EngramWeb.ErrorJSON]]` and no `error_html`
module exists, so Phoenix's default here was *already* a JSON 404. And the
deny-list routes lived in `pipeline :spa`, whose first plug is
`plug :accepts, ["html"]`, so a JSON client hitting a typo'd API path got a
**406** -- strictly worse than the 404 it now gets.

Deleting it also retires the "EVERY new non-SPA top-level prefix must be added
here" rule: 11 hand-maintained entries of exactly the kind this change set out
to remove.

## The bug this shipped with, and what now prevents it

Deleting the root `get "/:slug"` also deleted the only route that served
`/reset-password`. It was never on the static whitelist -- it had survived
purely by falling through the wildcard -- so self-host password recovery
became a hard 404. The link is minted server-side
(`admin/user_controller.ex`) and mailed to a user who is locked out, so it is
*always* a cold load. SaaS was spared only because `frontend/wrangler.jsonc`
sets `not_found_handling: "single-page-application"`.

Nothing caught it, and the reason generalises: **the invariant that decides
HTTP 200 vs 404 lives in Elixir, and every guard added with the refactor lived
in TypeScript.** `router.test.tsx` proved the React route existed;
`spa_controller_test.exs` never requested the path.

The fix is a shared manifest, `frontend/src/spa-routes.json`, listing URLs
that must survive a hard load. Two tests read it and both must pass:

- `frontend/src/router.test.tsx` -- each sample matches a React route, and no
  static top-level React route lacks a sample
- `test/engram_web/spa_route_parity_test.exs` -- each sample resolves in
  `EngramWeb.Router`, and `vaultPrefix` is what Phoenix actually serves

Neither list can drift without the other going red. Verified by mutation:
deleting the `/reset-password` route turns the Elixir test red and names the
path in the failure message.

## The guard that replaced the list

`frontend/src/router.test.tsx` walks the built router config and asserts no
route resolves to a root-level `/:param`. The bare catch-all `"*"` is exempt
(it is the 404 handler and RR ranks it last). That test fails if anyone
re-introduces a root wildcard, which is the thing the hand-maintained list
could never do.

Precedent for the pattern: `EngramWeb.Plugs.HostRewrite.__api_top_segments__`
is compared against `Router.__routes__` by its own regression test.

## Gotchas found while doing it

- **Grep for the shape, not the syntax.** The first sweep searched
  ``to={`/${``, ``navigate(`/${`` and ``pathname: `/${`` and missed 12 sites —
  `wiki-link.ts` builds hrefs with a bare ``return `/${slug}/...` ``. The
  correct sweep is ``grep -rn '`/\${' src/``.
- `wiki-link.test.ts` used `"v"` as its fixture slug, which made post-migration
  expectations read `/v/v/...`. Renamed the fixture to `work`.
- Nothing external deep-links to a vault URL. Every hardcoded app URL outside
  the SPA (`plugin/src/sync-progress-modal.ts`, `lib/engram/onboarding.ex`,
  the Clerk dashboard, `.well-known` OAuth metadata, marketing docs) points at
  an **app** route like `/settings/api-keys`. This is why moving the vault
  route was cheap and moving the app routes would not have been.

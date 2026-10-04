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
| ~~`/v/:slug/wiki/*`~~ | REMOVED 2026-09-02 — an unresolved wikilink creates the note on click instead of routing to an interstitial. Both shapes now sit in `spa-routes.json`'s `mustNotResolve`. |

Built in one place on the frontend:

```ts
// frontend/src/routes.ts
export const VAULT_PREFIX = "/v";
export function vaultPath(slug: string, itemId?: string): string
export function noteHref(slug: string | null | undefined, noteId: string): string
export function vaultRootHref(slug: string | null | undefined): string
```

Backend counterpart at the bottom of `lib/engram_web/router.ex`: three `get`s
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
  masked a broken API call.

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
reachable through the slug: `slugify` strips the dot. Any other user-named
path segment that keeps its dot (a note title, a wikilink target) is reachable,
and Cloudflare decodes `%2E` before rules run, so encoding does not help. Keep
user text out of URL paths, or put it in the query string.

## The deny-list went too

The router deny-list (`match :*, "/api/*path", SpaController, :not_found` and
10 siblings) is deleted. It added nothing: the app registers only
`EngramWeb.ErrorJSON`, so Phoenix's default for an unmatched path is already a
JSON 404. Worse, it lived in `pipeline :spa` (`plug :accepts, ["html"]`), so a
JSON client hitting a typo'd API path got a 406.

## The route-parity guard

The invariant that decides HTTP 200 vs 404 lives in Elixir, so a guard written
only in TypeScript misses it. Deleting the root `get "/:slug"` once broke
`/reset-password` on self-host (a mailed, always-cold link) while every
TypeScript test stayed green.

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
- Nothing external deep-links to a vault URL. Every hardcoded app URL outside
  the SPA (`plugin/src/sync-progress-modal.ts`, `lib/engram/onboarding.ex`,
  the Clerk dashboard, `.well-known` OAuth metadata, marketing docs) points at
  an **app** route like `/settings/api-keys`. This is why moving the vault
  route was cheap and moving the app routes would not have been.

# Vault URLs live under `/v/` — and the full slug-collision surface

**Trigger:** you are adding a top-level route, a `Plug.Static` mount, a Phoenix
scope, or a Cloudflare rule — and want to know whether it can collide with a
vault name. Or you found `@reserved_slugs` referenced somewhere and it no
longer exists.

## The shape

Vault-scoped SPA URLs are `/v/:slug` and `/v/:slug/:id`. Nothing dynamic sits
at the URL root. Built in one place:

```ts
// frontend/src/routes.ts
export const VAULT_PREFIX = "/v";
export function vaultPath(slug: string, itemId?: string): string
```

Backend counterpart: `get "/v/:slug"` / `get "/v/:slug/:id"` at the bottom of
`lib/engram_web/router.ex`.

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

The `ends_with` rules (`.sql`, `.bak`, `.backup`, `.old`, `.log`) were never
reachable — `slugify` strips the dot.

## What did NOT get deleted

The router **deny-list** (`match :*, "/api/*path", SpaController, :not_found`
and siblings) stays. Its original job — stopping fall-through to the root
wildcard — is gone, but its second job outlives it: it returns a clean
non-HTML 404 for API-shaped paths instead of Phoenix's default HTML error
page. Deleting it would turn `/api/notez` into an HTML error body, which is
the exact "masked as success" shape the tests guard against.

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

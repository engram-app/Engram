# Edge-caching a response whose HEADERS vary by request

_Last verified: 2026-08-18 against prod (`api.engram.page`, `mcp.engram.page`,
`app.engram.page`, `staging.engram.page`). Shipped in Engram#1422 +
engram-infra#1014._

## When you need this

You are about to make something edge-cacheable — adding
`Cache-Control: public` to a route, or adding a hostname or path to the
Cloudflare Cache Rule in `engram-infra/main/cloudflare/cache.tf`.

## The one idea

"The body is identical for every caller" is **not** sufficient for a shared
cache. The headers have to be identical too, and ours were not.

`EngramWeb.Plugs.CORS` echoes the request `Origin` back whenever it is in the
`:cors_origin` allowlist (`lib/engram_web/plugs/cors.ex`, `resolve_origin/1`).
Verified against prod:

```
Origin: https://mcp.engram.page   -> access-control-allow-origin: https://mcp.engram.page
Origin: https://api.engram.page   -> access-control-allow-origin: https://api.engram.page
Origin: https://evil.example.com  -> access-control-allow-origin: https://app.engram.page
```

Cache that and the edge stores **one** entry with whichever origin happened to
fill it. For the next 300s every other client gets that same header replayed,
so a browser on `app.engram.page` receives a document stamped for
`mcp.engram.page` and the fetch is CORS-blocked. Which client "wins" is a
race, so the symptom is intermittent, region-dependent, and clears itself in
five minutes — the worst possible bug report.

**`Vary: Origin` does NOT fix this.** Cloudflare honours `Vary` only for
`Accept-Encoding` on standard caching; any other `Vary` value is ignored and
the entry stays shared. This is the trap: `Vary` is the textbook answer, it
looks like it works, and at our edge it does nothing.

The fix is to make the header **constant** on exactly the routes that are
cached. `EngramWeb.Router`'s `:public_cacheable` pipeline pins
`access-control-allow-origin: *` alongside the `Cache-Control`, and both live
in one pipeline specifically so a third cached endpoint cannot pick up half
the pair.

`*` is safe **here** and is not a general licence: these are unauthenticated
RFC 8414 / RFC 9728 discovery documents and the OpenAPI spec, all fetchable by
anyone with no `Origin` at all. `*` is also incompatible with credentialed
CORS by construction, so it cannot widen access to anything holding a token.
Do not copy the `*` onto a route that answers differently per user.

## The checklist before caching anything

1. **Diff the full response headers, not the body**, from two different
   origins and two different hosts. Anything that differs is a poisoning
   vector.
2. **Check every host the path resolves on.** Same path, same zone, totally
   different response — measured 2026-08-18:

   | host | `/.well-known/oauth-*` | `/api/openapi` | `/openapi` |
   |---|---|---|---|
   | `api.engram.page` | 192 B (doc) | 72408 B | 72408 B |
   | `mcp.engram.page` | 184 B (doc) | 404 | 404 |
   | `app.engram.page` | **4339 B (SPA shell)** | **4339 B (SPA)** | **4339 B (SPA)** |
   | `staging.engram.page` | 200 B (doc) | 72408 B | **3940 B (SPA)** |

   A zone-wide Cache Rule would therefore have made the **SPA HTML shell**
   edge-cacheable on `app` under three paths. The shell sends no explicit
   `Cache-Control` (see `frontend/public/_headers`: the `/*` block sets
   security headers only), so `respect_origin` falls back to Cloudflare's own
   default TTL and pins a stale shell that survives a deploy and references
   purged asset hashes. That is an outage produced by a rule whose stated
   purpose was caching two JSON documents. The rule is now host-scoped to
   `api` + `mcp`.

3. **Match on the path the EDGE sees, not the one Phoenix routes.**
   `HostRewrite` maps bare `/openapi` -> `/api/openapi` on `api.engram.page`
   (`@api_top_segments` in `lib/engram_web/plugs/host_rewrite.ex`). That
   rewrite happens in Phoenix, *after* the edge has already matched. A rule
   listing only `/api/openapi` silently leaves the identical 72 KB body
   uncached on the bare form. It did exactly that until `curl` proved it.

4. **Know that edge and browser TTLs compound.** Both are `respect_origin`, so
   a browser fetching at edge-second 299 caches a further 300s: worst-case
   staleness per client is ~600s, not the 300s the header suggests.

## Things that are true and easy to get backwards

- **`Cache-Control: public` alone does nothing at our edge.** Cloudflare's
  default Cache Level only treats known static file extensions as eligible, so
  extensionless JSON stays `cf-cache-status: DYNAMIC` regardless of what the
  origin sends. The app header and the Cache Rule are each useless alone. If
  you see `DYNAMIC` after deploying, suspect the rule (or its host list), not
  the header.
- **Ordering between the two repos is safe either way.** If the infra rule
  lands first, the app is still sending Phoenix's default `private`, and
  `respect_origin` declines to cache. No window of wrongness.
- **`x-request-id` is cached with the body**, so a hit replays the request id
  of whichever request filled the cache. Use `cf-ray` to correlate these
  endpoints; the id is still accurate on a MISS.
- **`crossorigin` on a `rel=preconnect` is about connection POOLS, not
  credentials.** A hint naming the wrong pool is silently wasted — the real
  request opens a second connection while the hinted one idles. Verified that
  `@clerk/shared`'s `loadClerkJsScript.mjs` sets `crossOrigin: "anonymous"`,
  and saas API auth is a bearer header rather than a cookie, so bare
  `crossorigin` (= anonymous) is right for both hints in
  `frontend/public/_headers`. The one credentialed caller,
  `local-auth-provider.tsx`, is self-host and same-origin.
- **Early Hints are replayed per URL.** Cloudflare only sends `103` for a URL
  whose `Link` headers it has already observed, so a *novel* deep link gets no
  early-hints acceleration. The `Link` header still works as an ordinary
  response header there, so the preconnect happens — just not early.

## Regression cover

`test/engram_web/public_cacheable_headers_test.exs`. Two things worth knowing
if you touch it:

- It configures a **prod-shaped `:cors_origin` list**. The test-env default is
  `"*"`, under which the echo bug cannot reproduce at all — a test written
  against the default would have passed on the broken code.
- The health-check assertion asserts the **property** ("nothing `public`")
  rather than "is not this one exact string". A cached health check reports
  healthy from the edge while the app is down, which is worse than having no
  health check, and an exact-string assertion would miss
  `public, max-age=60`.

The test was confirmed to fail against the unfixed code before being trusted.

## Related

- `engram-infra/main/cloudflare/cache.tf` — the paired Cache Rule
- `frontend/public/_headers` — preconnect hints + SPA cache headers
- `docs/context/oauth-discovery-urls-behind-edge-tls.md` — the other way these
  discovery documents go wrong at the edge

# Dev iteration loop (frontend + backend)

How to make changes show up in a browser when iterating locally on this VM. Pattern is non-obvious; this doc exists because we hit a white-page mystery on 2026-04-30.

## TL;DR

- **Phoenix** (`make dev`): serves API + the **prod-built** SPA bundle from `priv/static/app/`. Listens on `:4000`.
- **Vite** (`make frontend-dev` / `bun run dev` in `backend/frontend`): hot-reload dev server on `:5173`. Proxies `/api` and `/socket` back to Phoenix on `:4000`.
- The user-facing host **`app.engram.page`** routes to this VM's Phoenix `:4000` via **Cloudflare → FastRaid nginx → Phoenix**. DNS for `app.engram.page` is proxied through Cloudflare; Cloudflare forwards to the FastRaid (10.0.20.214) nginx reverse proxy, which terminates TLS and upstreams to this dev VM on `:4000`. Vite (:5173) is reachable only as `localhost:5173`.

| Want                                | Hit                                  | Requires                                    |
| ----------------------------------- | ------------------------------------ | ------------------------------------------- |
| Frontend hot-reload while editing   | `http://localhost:5173/`         | `make frontend-dev` running                 |
| Test prod bundle locally            | `http://localhost:4000/`         | `make dev` running + `bun run build`        |
| Share with friends / external test  | `https://app.engram.page/`       | `make dev` running + `bun run build`        |
| **UI-only iteration, real Clerk + data, no local backend** | `http://localhost:5173/` (or `http://10.0.20.172:5173/` from LAN) | Vite pointed at staging — see "Iterating against staging" below |

> **Important:** `app.engram.page` only sees what Phoenix serves. To make changes visible there during dev, you must run `bun run build` inside `backend/frontend/` so Phoenix has the new static bundle to ship.

## Iterating against the staging backend (no local Phoenix)

_Added 2026-05-26._

For **pure frontend/UI work** (e.g. the onboarding wizard) you can skip running
Phoenix entirely and point the Vite dev server at the live **staging** backend.
You get HMR on your branch's UI, real Clerk auth, and real data — and crucially
**no local node joins the shared Oban queue** (see the Oban hazard below).

### Why not just `make dev` against the FastRaid DB?

`backend/.env.local` already points `DATABASE_URL` at FastRaid Postgres
(`10.0.20.214:35432/engram`) and Qdrant at `10.0.20.201:6333`. But Oban starts
unconditionally in `lib/engram/application.ex` with live queues
(`embed/reindex/maintenance/crypto_backfill` + Cron, see `config/config.exs`) and
there is **no dev/env override to disable it**. So a local `mix phx.server`
against that DB becomes a worker on the shared job queue — it will pull and run
real embedding jobs (Voyage cost), crypto_backfill, and cron against shared
Qdrant/data. The staging-proxy approach below sidesteps this completely.

### Setup

In `backend/frontend/.env.local` (gitignored):

```
VITE_AUTH_PROVIDER=clerk
VITE_CLERK_PUBLISHABLE_KEY=pk_test_a2V5LWxvbmdob3JuLTc5LmNsZXJrLmFjY291bnRzLmRldiQ
VITE_API_TARGET=https://staging.engram.page
```

The publishable key MUST be **staging's** Clerk instance. Get the current one with:

```
curl -s https://staging.engram.page/ | grep -o '__ENGRAM_CONFIG__[^<]*'
```

As of 2026-05-26 staging is Clerk instance **longhorn-79** (the key above). The
local backend's `.env.local` uses a *different* instance (`rare-kingfish-16`) —
using the wrong key gives 401s because staging won't validate JWTs minted by a
different instance.

`vite.config.ts` already carries the two changes this needs (committed): proxy
entries with `changeOrigin: true` + `secure: true`, and an IPv4-forcing preamble
(`dns.setDefaultResultOrder('ipv4first')` + `net.setDefaultAutoSelectFamily(false)`).

### Run it (under node, not bun)

```
make dev-ui-staging          # from backend/ — binds 0.0.0.0 for LAN access
```

That target expands to (run from `backend/frontend/`):

```
VITE_API_TARGET=https://staging.engram.page node node_modules/.bin/vite          # localhost only
VITE_API_TARGET=https://staging.engram.page node node_modules/.bin/vite --host 0.0.0.0   # reachable on LAN
```

Verify the proxy reaches staging (401 = reached backend, just unauthenticated):

```
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5173/api/billing/config   # expect 401
```

Then open `http://localhost:5173/` (or `http://10.0.20.172:5173/` from another LAN
machine) and sign in via Clerk.

### LAN access from another machine

- Bind with `--host 0.0.0.0` (default bind is `localhost` only).
- Open the VM firewall: `sudo firewall-cmd --add-port=5173/tcp` (runtime-only, no
  `--permanent`, auto-closes on reboot/reload). Tighter: scope to the subnet with a
  rich rule `source address="10.0.20.0/24"`. This VM's LAN IP is **10.0.20.172**.
- Connect by **IP**, not a hostname — Vite's `allowedHosts` permits IP literals but
  blocks unknown domain names ("Blocked request. This host is not allowed.").

### Failed approaches / dead ends

- **`bun run dev` against a remote https target → 502.** This VM has no IPv6
  route, staging's DNS returns AAAA records, and the proxy's happy-eyeballs races
  a dead IPv6 connect (`ENETUNREACH`), surfacing as `502 Bad Gateway` /
  `AggregateError [ECONNREFUSED]`. Bun **ignores** `NODE_OPTIONS`,
  `--dns-result-order`, and `net.setDefaultAutoSelectFamily`, so the config-level
  IPv4 fix doesn't take effect under bun. **Run under `node`.**
- **Passing the proxy a `family:4` https agent via the vite proxy `agent` option** —
  did not help (Vite 8's proxy ignored it). The working fix is the process-level
  `dns`/`net` preamble in `vite.config.ts`, which only applies under node.
- **Relying on `.env.local` for `VITE_API_TARGET` under node** — node does NOT
  auto-load `.env.local` into `process.env` (bun does), and `vite.config.ts` reads
  `process.env.VITE_API_TARGET`. So pass it inline on the node command. (Client
  vars like `VITE_AUTH_PROVIDER` still load fine — Vite reads `.env.*` into
  `import.meta.env` regardless of runtime.)

## The white-page gotcha (and the fix)

`EngramWeb.SpaController` injects the runtime `__ENGRAM_CONFIG__` script into `priv/static/app/index.html`. To avoid re-reading the file on every request, it caches the split-around-`</head>` result in `:persistent_term`.

**Original cache invalidation strategy:** none. The persistent term lived until the BEAM restarted.

**Failure mode:** `bun run build` rewrote `index.html` with a new asset hash (e.g. `index-BAZotJj3.js`) and **deleted** the old hashed file (`index-4FbQ3RR3.js`). Phoenix kept serving the cached pre-rebuild HTML pointing to the deleted asset. Browser 404'd on the JS module → React never mounted → white page. No console error in Phoenix logs — the HTML response is 200, only the asset request 404s.

**Symptom signature:**

- `curl http://localhost:4000/ | grep index-` returns an asset hash that is **not** present in `priv/static/app/assets/`.
- DevTools Network tab shows 404 on the JS module.
- DevTools Console shows nothing (the failure is at `<script type="module">` resolution, before any app code runs).

**Fix:** `config/dev.exs` sets `:spa_cache_enabled?` to `false`. SpaController checks this flag and skips the persistent_term in dev/test, rebuilding the split on every request. `index.html` is ~1KB so the cost is negligible. Prod keeps the cache (one read per BEAM lifetime).

If you ever see a white page on `:4000` or `app.engram.page` after a rebuild and the controller cache is somehow re-enabled, the recovery is `make dev-stop && make dev`.

## When to rebuild / restart

| Change                                          | Action                                                        |
| ----------------------------------------------- | ------------------------------------------------------------- |
| Edit `.ex` file                                 | Phoenix code-reloads automatically (Bandit + `Code.reload!`)  |
| Edit `config/dev.exs`                           | Restart Phoenix (`make dev-stop && make dev`)                 |
| Edit `.tsx`/`.ts`/`.css` and viewing on `:5173` | Vite hot-reloads automatically                                |
| Edit `.tsx`/`.ts`/`.css` and viewing on `:4000` or `app.engram.page` | `bun run build` in `backend/frontend/`. No Phoenix restart needed (cache disabled in dev). |

## Background-process recipe

When iterating with the user, start servers as backgrounded shells:

```
make dev                                                  # Phoenix :4000 only
make frontend-dev                                         # Vite :5173 (separate terminal, only if you want hot-reload)
```

> **Phoenix no longer auto-spawns Vite.** It used to via `config/dev.exs`'s
> `watchers:` list, but Phoenix launches watchers as Port children that
> survive `pkill -9` on the BEAM, leaving orphan `node` processes holding
> :5173, :5174, :5175… across restarts. Vite is now only started by
> explicit `make frontend-dev`.
>
> `make dev-stop` also kills any stray listeners on :5173–:5199 as a
> safety net.

Steer the user to `:5173` for fast feedback. If they're on `app.engram.page`, every UI change requires `bun run build` first. If the page goes white after a rebuild, suspect SPA cache (verify with the curl/grep above) before suspecting JS errors.

## Hosting path

`app.engram.page` is the alpha-test public host. Request flow:

1. Browser → `https://app.engram.page` (Cloudflare DNS, proxied/orange-cloud).
2. Cloudflare → FastRaid (`10.0.20.214`) over Cloudflare tunnel.
3. FastRaid nginx terminates TLS and reverse-proxies to this dev VM (Claw) on `:4000`.
4. Phoenix serves the API + prod-built SPA from `priv/static/app/`.

Because step 4 is **this** machine running `make dev`, every UI change still needs `bun run build` to be visible to external testers — same as hitting `localhost:4000` here. Pure-backend changes don't need a rebuild (Phoenix code-reloads on file save).

The marketing site at `engram.page` (apex) is unrelated and points elsewhere — only the `app.` subdomain proxies to this dev VM.

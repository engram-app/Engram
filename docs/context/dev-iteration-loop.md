# Dev iteration loop (frontend + backend)

How to make changes show up in a browser when iterating locally on this VM. Pattern is non-obvious; this doc exists because we hit a white-page mystery on 2026-04-30.

## TL;DR

- **Phoenix** (`make dev`): serves API + the **prod-built** SPA bundle from `priv/static/app/`. Listens on `:4000`.
- **Vite** (`make frontend-dev` / `bun run dev` in `backend/frontend`): hot-reload dev server on `:5173`. Proxies `/api` and `/socket` back to Phoenix on `:4000`.
- The user-facing host **`engram.ras.band`** (hosts file alias / external route) **routes to this VM's `:4000`**, i.e. to Phoenix. Vite (:5173) is reachable only as `localhost:5173`.

| Want                                | Hit                                  | Requires                                    |
| ----------------------------------- | ------------------------------------ | ------------------------------------------- |
| Frontend hot-reload while editing   | `http://localhost:5173/`         | `make frontend-dev` running                 |
| Test prod bundle locally            | `http://localhost:4000/`         | `make dev` running + `bun run build`        |
| Share with friends / external test  | `https://engram.ras.band/`       | `make dev` running + `bun run build`        |

> **Important:** `engram.ras.band` only sees what Phoenix serves. To make changes visible there during dev, you must run `bun run build` inside `backend/frontend/` so Phoenix has the new static bundle to ship.

## The white-page gotcha (and the fix)

`EngramWeb.SpaController` injects the runtime `__ENGRAM_CONFIG__` script into `priv/static/app/index.html`. To avoid re-reading the file on every request, it caches the split-around-`</head>` result in `:persistent_term`.

**Original cache invalidation strategy:** none. The persistent term lived until the BEAM restarted.

**Failure mode:** `bun run build` rewrote `index.html` with a new asset hash (e.g. `index-BAZotJj3.js`) and **deleted** the old hashed file (`index-4FbQ3RR3.js`). Phoenix kept serving the cached pre-rebuild HTML pointing to the deleted asset. Browser 404'd on the JS module → React never mounted → white page. No console error in Phoenix logs — the HTML response is 200, only the asset request 404s.

**Symptom signature:**

- `curl http://localhost:4000/ | grep index-` returns an asset hash that is **not** present in `priv/static/app/assets/`.
- DevTools Network tab shows 404 on the JS module.
- DevTools Console shows nothing (the failure is at `<script type="module">` resolution, before any app code runs).

**Fix:** `config/dev.exs` sets `:spa_cache_enabled?` to `false`. SpaController checks this flag and skips the persistent_term in dev/test, rebuilding the split on every request. `index.html` is ~1KB so the cost is negligible. Prod keeps the cache (one read per BEAM lifetime).

If you ever see a white page on `:4000` or `engram.ras.band` after a rebuild and the controller cache is somehow re-enabled, the recovery is `make dev-stop && make dev`.

## When to rebuild / restart

| Change                                          | Action                                                        |
| ----------------------------------------------- | ------------------------------------------------------------- |
| Edit `.ex` file                                 | Phoenix code-reloads automatically (Bandit + `Code.reload!`)  |
| Edit `config/dev.exs`                           | Restart Phoenix (`make dev-stop && make dev`)                 |
| Edit `.tsx`/`.ts`/`.css` and viewing on `:5173` | Vite hot-reloads automatically                                |
| Edit `.tsx`/`.ts`/`.css` and viewing on `:4000` or `engram.ras.band` | `bun run build` in `backend/frontend/`. No Phoenix restart needed (cache disabled in dev). |

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

Steer the user to `:5173` for fast feedback. If they're on `engram.ras.band`, every UI change requires `bun run build` first. If the page goes white after a rebuild, suspect SPA cache (verify with the curl/grep above) before suspecting JS errors.

## TODO

Document the actual mechanism that makes `engram.ras.band` resolve to this VM's `:4000` (hosts file? Tailscale Funnel? Cloudflare tunnel? reverse proxy on FastRaid?). The "alpha test" plan depends on friends hitting this URL externally — needs a deploy target description, not just a dev-loop description.

# Dev iteration loop (frontend + backend)

_Last verified: 2026-10-03_

How to make changes show up in a browser when iterating locally on this VM. For bringing up a dev stack (`make saas-dev` / `make dev-selfhost`, port contract), see `../engram-workspace/docs/context/engram-dev-modes.md`.

## TL;DR

- **Phoenix** (`make dev`): serves API + the **prod-built** SPA bundle from `priv/static/app/`. Listens on `:4000` (localhost only).
- **Vite** (`make frontend-dev` / `bun run dev` in `backend/frontend`): hot-reload dev server on `:5173`. Proxies `/api` and `/socket` back to Phoenix on `:4000`.
- This loop is **local-only**. A local `bun run build` updates only this machine's `localhost:4000`; it never reaches staging or prod. For shipping, see `docs/context/deploy-prod.md` and `docs/context/frontend-ship-verification-bundle-grep.md`.

| Want                                | Hit                                  | Requires                                    |
| ----------------------------------- | ------------------------------------ | ------------------------------------------- |
| Frontend hot-reload while editing   | `http://localhost:5173/`         | `make frontend-dev` running                 |
| Test prod bundle locally            | `http://localhost:4000/`         | `make dev` running + `bun run build`        |

> **Important:** to make a UI change visible at `localhost:4000`, run `bun run build` inside `backend/frontend/` so Phoenix has the new static bundle.

## The white-page gotcha (and the fix)

`EngramWeb.SpaController` injects the runtime `__ENGRAM_CONFIG__` script into `priv/static/app/index.html`. To avoid re-reading the file on every request, it caches the split-around-`</head>` result in `:persistent_term`.

If that cache survives a `bun run build`, Phoenix serves HTML pointing at a deleted hashed asset: the JS module 404s, React never mounts, white page, nothing in Phoenix logs.

**Symptom signature:**

- `curl http://localhost:4000/ | grep index-` returns an asset hash that is **not** present in `priv/static/app/assets/`.
- DevTools Network tab shows 404 on the JS module.
- DevTools Console shows nothing (the failure is at `<script type="module">` resolution, before any app code runs).

**Fix:** `config/dev.exs` sets `:spa_cache_enabled?` to `false`. SpaController checks this flag and skips the persistent_term in dev/test, rebuilding the split on every request. `index.html` is ~1KB so the cost is negligible. Prod keeps the cache (one read per BEAM lifetime).

If you ever see a white page on `localhost:4000` after a rebuild and the controller cache is somehow re-enabled, the recovery is `make dev-stop && make dev`. (The same caching mechanism exists in prod, but prod gets a fresh BEAM per deploy, so a stale-cache white page can't survive a deploy.)

## When to rebuild / restart

| Change                                          | Action                                                        |
| ----------------------------------------------- | ------------------------------------------------------------- |
| Edit `.ex` file                                 | Phoenix code-reloads automatically (Bandit + `Code.reload!`)  |
| Edit `config/dev.exs`                           | Restart Phoenix (`make dev-stop && make dev`)                 |
| Edit `.tsx`/`.ts`/`.css` and viewing on `:5173` | Vite hot-reloads automatically                                |
| Edit `.tsx`/`.ts`/`.css` and viewing on `localhost:4000` | `bun run build` in `backend/frontend/`. No Phoenix restart needed (cache disabled in dev). |

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

Steer the user to `:5173` for fast feedback. If they're on `localhost:4000`, every UI change requires `bun run build` first. If the page goes white after a rebuild, suspect SPA cache (verify with the curl/grep above) before suspecting JS errors.

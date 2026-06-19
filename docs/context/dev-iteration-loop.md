# Dev iteration loop (frontend + backend)

How to make changes show up in a browser when iterating locally on this VM. Pattern is non-obvious; this doc exists because we hit a white-page mystery on 2026-04-30.

## TL;DR

- **Phoenix** (`make dev`): serves API + the **prod-built** SPA bundle from `priv/static/app/`. Listens on `:4000` (localhost only).
- **Vite** (`make frontend-dev` / `bun run dev` in `backend/frontend`): hot-reload dev server on `:5173`. Proxies `/api` and `/socket` back to Phoenix on `:4000`.
- This loop is **local-only**. Nothing here ships to a public host. `app.engram.page` is **AWS ECS Fargate PROD** and is reached only by pushing a `release-v*` tag (GitOps); `staging.engram.page` is **FastRaid staging**. A local `bun run build` updates only this machine's `localhost:4000` — it does NOT reach prod or staging. (See `docs/context/deploy-prod.md`.)

| Want                                | Hit                                  | Requires                                    |
| ----------------------------------- | ------------------------------------ | ------------------------------------------- |
| Frontend hot-reload while editing   | `http://localhost:5173/`         | `make frontend-dev` running                 |
| Test prod bundle locally            | `http://localhost:4000/`         | `make dev` running + `bun run build`        |
| Ship to staging                     | `staging.engram.page`            | merge to `main` (auto-deploys FastRaid)     |
| Ship to prod                        | `app.engram.page`                | push a `release-v*` tag (GitOps → AWS ECS)  |

> **Important:** the `:4000` page on this machine only sees what Phoenix serves locally. To make a UI change visible at `localhost:4000`, run `bun run build` inside `backend/frontend/` so Phoenix has the new static bundle to ship. This has no effect on staging/prod.

## The white-page gotcha (and the fix)

`EngramWeb.SpaController` injects the runtime `__ENGRAM_CONFIG__` script into `priv/static/app/index.html`. To avoid re-reading the file on every request, it caches the split-around-`</head>` result in `:persistent_term`.

**Original cache invalidation strategy:** none. The persistent term lived until the BEAM restarted.

**Failure mode:** `bun run build` rewrote `index.html` with a new asset hash (e.g. `index-BAZotJj3.js`) and **deleted** the old hashed file (`index-4FbQ3RR3.js`). Phoenix kept serving the cached pre-rebuild HTML pointing to the deleted asset. Browser 404'd on the JS module → React never mounted → white page. No console error in Phoenix logs — the HTML response is 200, only the asset request 404s.

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

## Hosting path (where each host actually lives)

This local dev loop does **not** front any public host. The public hosts are deployed infrastructure, not this VM:

- **`app.engram.page`** → **AWS ECS Fargate PROD** (RDS + S3). Updated only by GitOps: push a `release-v*` tag → engram-infra Terraform reconciles the ECS image tag → service rolls. See `docs/context/deploy-prod.md`.
- **`staging.engram.page`** → **FastRaid staging** (`10.0.20.214`). Auto-deployed on merge to `main`.
- **`engram.page`** (apex) → the marketing site, unrelated to the app.

A local `bun run build` only updates this machine's `localhost:4000`; it never reaches prod or staging. To get a change in front of external testers, ship it to staging (merge) or prod (release tag). Pure-backend changes still code-reload locally on file save (Bandit + `Code.reload!`).

> **Historical note:** an earlier alpha setup did proxy `app.engram.page` → Cloudflare → FastRaid → this dev VM:4000. That topology is dead — `app.engram.page` is AWS prod now. Do not assume a `bun run build` here is visible at any public host.

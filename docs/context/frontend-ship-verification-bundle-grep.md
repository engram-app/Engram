# Verifying a frontend change actually shipped — grep every chunk, not the entry bundle

_Last verified: 2026-09-16_

## Symptom

Grepped the deployed SPA entry bundle on staging (`index-D0k_chkZ.js`) for identifiers
added by a frontend fix — `gate_ok`, `tools_prefilled`, new UI copy — got **zero hits**,
and nearly reported "staging does not have the frontend fix". The same method had already
been used to claim prod was clean.

Both conclusions were unfounded. The code was deployed.

## Root cause

The SPA is a Vite build with **route-level code splitting**: route components are
`lazy(() => import(...))` in `frontend/src/router.tsx`, so they compile into separate
chunks that the entry bundle only *references* by filename. A route component's source
never appears in `index-*.js`.

**A zero-hit grep of the entry bundle is evidence of nothing.** It cannot distinguish
"not deployed" from "deployed in a chunk you did not fetch".

## Correct method

Read the entry bundle to extract the chunk filenames it references, then sweep every chunk:

```bash
BASE=https://staging.engram.page      # or https://app.engram.page for prod
NEEDLE=gate_ok

ENTRY=$(curl -s "$BASE/" | grep -oE '/assets/[A-Za-z0-9._-]+\.js' | head -1)
# Chunk filenames appear as string literals inside the entry bundle.
curl -s "$BASE$ENTRY" \
  | grep -oE '[A-Za-z0-9._-]+-[A-Za-z0-9_-]{8}\.js' | sort -u \
  | while read -r chunk; do
      curl -s "$BASE/assets/$chunk" | grep -q "$NEEDLE" && echo "HIT: $chunk"
    done
```

Doing that found the code immediately:

- `oauth-authorize-page-CryifFKc.js` — `gate_ok`, `tools_prefilled`, the new copy
- `onboard-entry-D-Zw3xFr.js` — "Cancel connection"

Prod was then re-checked properly with the full sweep (60 chunks) and confirmed clean —
i.e. the fix genuinely had not reached prod traffic yet, for the reason below.

## Related trap: backend `version` does not move on a non-release deploy

While verifying the same deploy, staging's `/api/health` still reported `version: 0.28.0`
after the merge landed, which looks like "the deploy did not happen".

`version` reads `mix.exs`, which release-please keeps **sticky between release cuts** — it
tracks the last release tag, not the running bytes. **`build_sha` is the field to trust**
(baked in at image build time via `ARG RELEASE_SHA`; see
`lib/engram_web/controllers/health_controller.ex`). At the time of this check staging was
on `80ec292d` (the merge commit) and prod on `426ad302` — which is what actually answered
"did my merge ship?".

See `docs/context/prod-release-verification-gotchas.md` for the rest of that family.

## Related trap: a main merge cannot move prod frontend traffic

- `deploy-frontend` in `.github/workflows/verify.yml` runs on **every** push to main
  (unconditionally, not just when `frontend/` changed) and only runs
  `wrangler versions upload --tag "sha-<7>"` — that **publishes a version without shifting
  traffic**.
- Only `.github/workflows/frontend-promote.yml` runs
  `wrangler versions deploy "<id>@100%"`, and it fires on `repository_dispatch`
  (`frontend-promote`) from engram-infra's prod `terraform (prod)` apply, or manually via
  `workflow_dispatch`.

So merging to main mints a zero-traffic Cloudflare version and nothing more. The
`concurrency: group: deploy-frontend-prod` name on the upload job is misleading — that job
is not a prod deploy.

## Gotchas

- Chunk filenames carry content hashes, so they change every build; never hardcode one
  into a check script or a runbook.
- Grep the *identifier*, not the source line — minification renames locals but preserves
  string literals, object keys sent over the wire (`gate_ok`, `tools_prefilled`) and UI
  copy.
- "The entry bundle hash changed" is also not proof your change shipped; any main push
  rebuilds it.

## References

- `frontend/src/router.tsx` — the `lazy()` route imports that create the chunks
- `.github/workflows/verify.yml` — `deploy-frontend` job (upload only)
- `.github/workflows/frontend-promote.yml` — the only traffic-shifting deploy
- `lib/engram_web/controllers/health_controller.ex` — `version` vs `build_sha`
- `docs/context/prod-release-verification-gotchas.md`
- `docs/context/frontend-backend-deploy-skew-cors.md`

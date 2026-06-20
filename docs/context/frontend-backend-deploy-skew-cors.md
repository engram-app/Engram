# Context Doc: Frontend/Backend Deploy Skew + CORS Allowlist

_Last verified: 2026-06-20_

## Status
Working (fixed) — the specific CORS gap was closed in PR #675 (release-v0.5.489). The
**systemic deploy-skew hazard described below is permanent** and must be designed
around on every frontend↔backend contract change.

## What This Is
A production incident on 2026-06-20 where `app.engram.page` could not reach the API,
and — more importantly — the non-obvious systemic cause behind it: **the frontend and
backend deploy on different triggers, so frontend code can reach prod against a backend
that doesn't yet support it.**

## The Incident (2026-06-20)
- Symptom: `app.engram.page` could not reach the API. Browser console showed:
  > Request header field x-device-id is not allowed by Access-Control-Allow-Headers in preflight response
  plus `ERR` failures on `https://api.engram.page/onboarding/status`.
- Immediate root cause: `EngramWeb.Plugs.CORS` (`lib/engram_web/plugs/cors.ex`) advertised
  `access-control-allow-headers: authorization, content-type, x-vault-id` — **missing
  `x-device-id`**. The web SPA sends `X-Device-Id` on every request
  (`frontend/src/api/client.ts`, added in PR #630 for the cursor-pull gap-filler) and the
  backend reads it (`sync_controller.ex`), but nobody added it to the preflight allowlist.
- Fix: PR #675 (release-v0.5.489) added `x-device-id` to the allowlist (same shape as the
  earlier `x-vault-id` addition) plus a regression test in
  `test/engram_web/plugs/cors_test.exs`.

## The Systemic Cause — Deploy Skew (the real reason this doc exists)
The frontend and backend ship on **different triggers**:

| Surface | Host | Deploy trigger | Gating |
|---|---|---|---|
| Frontend | `app.engram.page` (Cloudflare Worker `engram-frontend`) | **Any merge to main touching `frontend/`** — `deploy-frontend` job in `verify.yml` + wrangler | merge-gated, instant |
| Backend | `api.engram.page` (AWS ECS) | **`release-v*` tag only** → `deploy-prod.yml` → engram-infra image-bump PR → tf-apply daemon → ECS | release-gated |

**The hazard:** a frontend deploy ships *all* accumulated frontend changes that merged
earlier but were never deployed (because no `frontend/` change had triggered a deploy
since). When the next `frontend/` PR finally triggers a deploy, it pushes the entire
backlog of frontend code live against **whatever backend version prod is currently pinned
to**. If any of that frontend code depends on an unreleased backend change (new header,
new endpoint, new contract), prod breaks.

**This incident, concretely:**
- PR #630's `X-Device-Id` frontend code had sat merged-but-undeployed.
- An unrelated, frontend-only perf PR (#673) was the first `frontend/` deploy since.
- #673 shipped #630's `X-Device-Id` live — against a prod backend (0.5.447) whose CORS
  allowlist didn't permit the header.
- Backend support reached prod only with the dedicated release-v0.5.489 fix.

## Prevention / Takeaways
- When a frontend change introduces a **new request header / endpoint / contract
  dependency** on the backend, the backend support MUST reach prod via a `release-v*` tag
  **before or together with** the frontend reaching prod — not merely merged to main.
- **Any new header the SPA sends must be added to `cors.ex` allow-headers in the SAME
  change**, and that backend change must be *released* to prod.
- Treat **"first frontend deploy in a while"** as potentially shipping a backlog of
  merged-but-undeployed frontend code. A frontend-only PR can expose latent skew it had
  nothing to do with.

## Failed Approaches / Dead Ends
- Reading the symptom as "x-device-id rejected" and stopping at the CORS one-liner misses
  the systemic cause. The CORS allowlist was the *trigger surface*; the deploy-skew is why
  a header that had been in the codebase for a while suddenly broke prod with no related
  change deployed that day.

## Deploy-Chain Gotchas Hit During the Fix
These bit during the release of the fix itself. Don't re-explain — cross-reference:
- The `deploy-prod` → engram-infra image-bump PR's `terraform (prod)` plan can fail with
  `reading ECR Images: couldn't find resource` if it plans **before** `build-and-publish-image`
  finishes pushing the image to ECR (a race). Remedy: re-run the failed checks once the
  image is in ECR.
- The `bot/bump-engram-prod` PR is signed-commit and can land **behind** main. Do **NOT**
  rebase it (rebasing strips the App signature → merge blocked). Remedy: delete the bot
  branch + re-run `deploy-prod` to get a fresh signed PR off current main.
  See feedback memory `feedback_no_rebase_signed_bot_pr` and the broader deploy-guardrails
  runbook (`engram-workspace/docs/context/deploy-guardrails.md`).

## References
- `lib/engram_web/plugs/cors.ex` — the CORS allowlist
- `test/engram_web/plugs/cors_test.exs` — regression test for the allow-headers list
- `frontend/src/api/client.ts` — where the SPA sets `X-Device-Id` (PR #630)
- `lib/engram_web/controllers/sync_controller.ex` — backend reader of `X-Device-Id`
- `.github/workflows/verify.yml` — `deploy-frontend` job (merge-gated frontend deploy)
- `.github/workflows/deploy-prod.yml` — release-gated backend deploy
- `engram-workspace/docs/context/deploy-guardrails.md` — deploy-chain triage runbook
- PRs: #630 (X-Device-Id frontend), #673 (perf PR that triggered the skewed deploy),
  #675 (CORS fix, release-v0.5.489)

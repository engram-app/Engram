# Context Doc: What the MCP conformance suite does and does not prove

_Last verified: 2026-08-05_

## Status
`scripts/mcp-conformance.sh` works and is verified against staging, but is **not yet wired into CI** — run it by hand for now.

It briefly rode a daily cron. That was wrong: a cron grades a *deployment*, and on a PR the deployment still runs `main`, so it can never gate the code under review — it reports a regression the morning after it merges. The target is a per-PR gate against the PR's own build; see "Getting it gating" below.

The two spec violations this doc is about are **already covered by ExUnit** (`mcp_transport_test.exs`, `well_known_controller_test.exs`), which does gate every PR. What is missing is the third-party-client signal, not regression protection for these specific bugs.

## What This Is
The MCPJam conformance runner is a **client compatibility tester**, not a spec auditor. It answers "can MCPJam connect to you", and it is deliberately generous about anything it can work around. Twice now that gap has let a real defect sit under a green suite. This doc records where the tool stops and what we assert ourselves, so the next person does not re-derive it.

## The trap: green means "a lenient client coped", not "we are compliant"

Two production spec violations survived a passing suite (found 2026-08-05, fixed in the same PR):

| Violation | Why MCPJam passed anyway |
|---|---|
| 401 carried no `WWW-Authenticate` (RFC 9728 §5.1, MCP 2025-06-18+) | It guesses the well-known convention instead. Its own step text calls the header something servers "*often*" provide. |
| No metadata at the RFC 9728 §3.1 path (`/.well-known/oauth-protected-resource/api/mcp`) | It tries the strict path, gets a 404, silently retries the root form, records the step as `passed`. |

Both are visible in the artifact if you read `httpAttempts` — the fallback is right there. Neither shows up in the verdict.

**Rule:** anything the spec *mandates* but a generous client *tolerates* must be asserted by us. That is STAGE 1 of the script — plain `curl` assertions, unauthenticated, so they grade fully regardless of the consent gate.

## Three ways this suite can report on work it never did

Each of these produced a tidy green (or tidy-looking) report at some point:

1. **Empty/reshaped `steps`** — the grader collected failures and passed when it found none, so zero steps read as "reached the consent gate cleanly (0 steps passed)". Guard: assert `authorization_request` passed.
2. **`--conformance-checks` produced zero checks** — it runs negative checks *after* the main flow, and ours cannot complete headlessly (Clerk consent). The flag was removed; it implied coverage it never delivered. Restore only if consent is driven from Playwright.
3. **`protocol conformance` skips 29 of 32 checks without a token** — and still prints a report. Guard: a skipped check is a failure, and a missing `ENGRAM_CONFORMANCE_TOKEN` fails the stage outright.

The shape is always the same: *no failures found* ≠ *checks ran*. Every grader here asserts positively that work happened.

## Gotchas

- **`--protocol-version` unset is the WEAKEST setting**, not the most permissive. `protocol conformance` defaults to "legacy (2025-era) behavior". Omitting it buys less coverage. We run the full matrix instead: `2025-03-26 2025-06-18 2025-11-25 2026-07-28`.
- **The matrix has invalid cells.** CIMD did not exist before `2025-11-25`; the CLI returns `{"error":{"code":"USAGE_ERROR"}}` for those two combinations. Graded as N/A (exit 2), but each strategy must grade ≥1 cell or that is a hard failure — otherwise a typo'd flag turns the whole strategy into a silent N/A.
- **The CLI exit code is not the verdict.** It exits non-zero unless the *whole* flow completes, which ours cannot. `|| true` plus the grader is deliberate; an earlier revision branched on the exit code and reported a clean pass against a server we knew was broken.
- **A healthy `received_authorization_code` is HTTP 200, not 302.** The CLI follows the redirect, so the status recorded is the consent SPA's. `400` there is `render_client_error("invalid_client")` — the real bug shape from #1241.
- **`set -o pipefail` when piping the script in CI.** GitHub's default shell is `bash -e` *without* pipefail, so `script | tee log` reports tee's status and every regression lands green.
- **Exit 2 means environment** (npm or target unreachable), and the CI job keys on it so a DNS blip does not open "the auth server is broken".

## Key Commands
```bash
scripts/mcp-conformance.sh                                  # staging
scripts/mcp-conformance.sh https://mcp.engram.page/api/mcp  # prod

# Stage 1 assertions by hand — these catch the class the runner misses:
curl -sS -D - -o /dev/null -X POST -d '{}' https://staging.engram.page/api/mcp | grep -i www-authenticate
curl -sS -o /dev/null -w '%{http_code}\n' https://staging.engram.page/.well-known/oauth-protected-resource/api/mcp
```

## Gotcha: prod and staging legitimately differ
`mcp.engram.page` advertises the **bare host** as the resource (HostRewrite serves MCP at `/`, see #634), so the *root* well-known is its spec-correct metadata location and the §3.1 path form does not apply. Every other host (staging, selfhost `engram.ax`, `app`/`api`) advertises the `/api/mcp` path and needs the §3.1 form. `EngramWeb.OAuthMetadata` derives both from one place so the document and the `WWW-Authenticate` pointer cannot drift — a mismatch there fails the client *after* it successfully fetches both, which is the least debuggable shape of this bug.

## Which stages can gate a PR (measured 2026-08-05)

Established by running the suite against a CI stack built from the branch, not by reasoning about it. Two of three stages cannot gate, for different reasons, and neither is a preference.

| Stage | Against a CI stack | Gates a PR |
|---|---|---|
| `spec` (our RFC 9728 assertions) | passes in ~4.5s | **yes** |
| `oauth` (MCPJam matrix) | refused — loopback | no, structurally |
| `protocol` (32 checks) | genuinely red | not yet — #1259 |

**`oauth` cannot target a CI stack, ever.** MCPJam's SDK ships an SSRF guard, `assertOutboundOAuthUrlAllowed`, refusing outbound OAuth metadata fetches to RFC 6890 special-use addresses unless the caller opts in — and the CLI exposes no such flag in 3.18.0 or 3.19.0:

```
Refusing outbound OAuth fetch to loopback host "localhost" (no loopback opt-in)
```

It defends against a hostile MCP server steering a fetch at `169.254.169.254` or a LAN service, which is worth having. There is no workaround from our side: a private LAN address is equally refused, and a hostname resolving to loopback is caught by their DNS revalidation. This stage needs a publicly-addressed deployment.

**`protocol` is red for real reasons** — `ping` unimplemented, no Host-rebinding rejection, and we announce protocol `2025-03-26`. Filed as #1259. It is excluded from the gate rather than having its failing checks excluded, because the latter is the exact silent-green this document is about.

**Gotcha: the CLI writes advisories to STDOUT, ahead of the JSON.** `json.load` on the raw capture therefore fails and the run reports NO SIGNAL — a harness fault wearing a server verdict's clothes. `scripts/lib/report_io.py` locates the document and keeps the preamble (it often explains the failures beneath it). Redirecting stderr does not help; these are stdout.

## Getting it gating

The blocker was never Playwright — it is that the suite must run against **the PR's own build**, not staging. The e2e stack already provides that, and the pieces are all present:

- `e2e-browser` boots the PR's backend on a dynamic port, including a Clerk-enabled variant (`PW_CLERK_BACKEND_PORT`).
- `e2e/tests/api_only/test_71_connections.py` already drives the **whole** OAuth flow headlessly — `register_client` → `consent(jwt_token, client_id)` → `_extract_code` → `exchange_code`. Consent is approved with a Clerk JWT against the consent endpoint. **No browser automation is required**, which was the assumption that made this look expensive.
- `e2e/helpers/auth_provider.py` and `clerk_auth.py` mint a user plus an API key, so `ENGRAM_CONFORMANCE_TOKEN` does not need to exist as a repo secret at all — a local stack mints its own.

Remaining work:

1. Host the script as an `api_only` e2e test pointed at the local backend. Gates on every PR via `e2e-clerk`; stages 1–3 all grade, and the token secret disappears.
2. Complete the flow past consent by driving the CLI with `--auth-mode interactive --print-url` and approving the emitted URL with the existing JWT helper. That un-skips `token_request`, `received_tokens`, `authenticated_mcp_request`, and restores the `--conformance-checks` negative checks (invalid client, invalid redirect, token format), which have never run.
3. Make sure the fingerprint does not skip it for OAuth-relevant diffs (`lib/engram/oauth/**`, `lib/engram_web/controllers/oauth_*`, `well_known_controller`, `router.ex`, this script). A gating job that fingerprint-skips is gating in name only.

## Related
- `docs/context/cimd-vs-dcr-validation-policy.md` — why DCR and CIMD validate differently
- `docs/context/staging-mcp-oauth-connect.md` — the proxy/route/metadata failure chain for a client that cannot connect at all

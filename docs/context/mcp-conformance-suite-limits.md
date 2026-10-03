# Context Doc: What the MCP conformance suite does and does not prove

_Last verified: 2026-10-03_

## Status
`scripts/mcp-conformance.sh` works and **is wired into CI**: `cron.yml` runs the `mcp-conformance` job daily at 05:40 UTC over a two-cell matrix — staging (`stages: spec,oauth`) and prod (`stages: spec`). It passes.

Note what that matrix reaches. **The OAuth/CIMD stage runs against staging only**; prod gets the RFC 9728 assertions and nothing else, deliberately, because the OAuth stage performs real DCR and CIMD registrations that write client rows.

A cron grades a *deployment*, not a PR: on a PR the deployment still runs `main`, so it reports a regression the morning after it merges. The per-PR gate is `e2e/tests/api_only/test_88_mcp_conformance.py`, which runs the script against the CI stack with `GATED_STAGES = "spec"`; the stack mints its own key, so no `ENGRAM_CONFORMANCE_TOKEN` secret is needed.

The two spec violations this doc is about are **already covered by ExUnit** (`mcp_transport_test.exs`, `well_known_controller_test.exs`), which does gate every PR. What is missing is the third-party-client signal, not regression protection for these specific bugs — and see "CIMD coverage is one vendor's document" for the limit a green cron hides.

## What This Is
The MCPJam conformance runner is a **client compatibility tester**, not a spec auditor. It answers "can MCPJam connect to you", and it is deliberately generous about anything it can work around. Twice now that gap has let a real defect sit under a green suite. This doc records where the tool stops and what we assert ourselves, so the next person does not re-derive it.

## CIMD coverage is one vendor's document

`--registration cimd` takes **no client-id argument**: MCPJam's CLI supplies its own published metadata document. So the entire CIMD matrix proves one thing — *MCPJam* can register with us via CIMD — across four protocol versions. It says nothing about any other vendor, because no other vendor's document is ever fetched.

That is not a gap in the runner; it is what a client compatibility tester is. The consequence is the part worth internalising:

> A suite that only exercises clients that already work cannot report a client that does not.

Found the hard way on 2026-09-14: ChatGPT declares `private_key_jwt`, the CIMD path then refused every method but `none`, and every ChatGPT connect failed while this suite ran green (#1633, #1635, both closed).

**Rule:** listing a vendor as supported in `docs/context/connections-client-identity.md` is not backed by anything in this suite. Vendor acceptance is `Engram.OAuth.Cimd.VendorConformanceTest`: it fetches real vendor documents and runs them through the CIMD validator. It is opt-in (`VENDOR_CONFORMANCE=1`) and runs from `cron.yml`, so a vendor outage cannot block a merge. Add a vendor's document there when you claim support for it.

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

## Which stages can gate a PR (measured 2026-08-05; protocol re-measured 2026-09-17)

Established by running the suite against a CI stack built from the branch, not by reasoning about it. Two of three stages cannot gate, for different reasons, and neither is a preference.

| Stage | Against a CI stack | Gates a PR |
|---|---|---|
| `spec` (our RFC 9728 assertions) | passes in ~4.5s | **yes** |
| `oauth` (MCPJam matrix) | refused — loopback | no, structurally |
| `protocol` (32 checks) | 0 failed, always some skipped | **no, structurally** |

**`oauth` cannot target a CI stack, ever.** MCPJam's SDK ships an SSRF guard, `assertOutboundOAuthUrlAllowed`, refusing outbound OAuth metadata fetches to RFC 6890 special-use addresses unless the caller opts in — and the CLI exposes no such flag in 3.18.0 or 3.19.0:

```
Refusing outbound OAuth fetch to loopback host "localhost" (no loopback opt-in)
```

It defends against a hostile MCP server steering a fetch at `169.254.169.254` or a LAN service, which is worth having. There is no workaround from our side: a private LAN address is equally refused, and a hostname resolving to loopback is caught by their DNS revalidation. This stage needs a publicly-addressed deployment.

**`protocol` cannot gate, and the reason is now structural rather than "we have bugs to fix".** Measured 2026-09-17 against staging at `e8aadd6e`, all four cells are **0 failed**:

```
PROTOCOL — 2025-03-26: 32 checks, 0 failed, 22 skipped
PROTOCOL — 2025-06-18: 32 checks, 0 failed, 22 skipped
PROTOCOL — 2025-11-25: 32 checks, 0 failed, 22 skipped
PROTOCOL — 2026-07-28: 32 checks, 0 failed, 15 skipped
```

and the script still exits **1**, on every single one.

That is `grade_protocol_conformance.py` doing its job: *"A skipped check is a failure here… Exit 0 = every check ran and passed."* The rule is correct and must stay — it is what stopped the 2026-08-05 silent-green.

But it means **the stage can never exit 0 for us**, because some skips are permanent by construction and no amount of work removes them:

| Skip | Why it can never run |
|---|---|
| `server-initialize`, `ping` at `2026-07-28` | the revision *removes* them — "not applicable to the modern era" |
| the 11 `modern-*` checks on any legacy revision | same in reverse |
| `localhost-host-rebinding-rejected` / `-valid-accepted` | only apply to a localhost server; we test a remote host |
| `logging-set-level`, `completion-complete`, `modern-resource-not-found` | optional capabilities we deliberately do not advertise |
| the 3 `subscriptions/*` checks | need `listChanged: true`, which we do not claim |

So do **not** flip `GATED_STAGES` to `"spec,protocol"`. It would be red forever, on a green server. This was proposed twice on 2026-09-17 before the exit code was actually traced — the summary line says "0 failed" and it is easy to assume `rc=1` means a cell is broken. Trace the grader, not the summary.

**What protects this work instead:** ExUnit. `mcp_modern_era_test.exs` (29 tests) and the `outputSchema`/`structuredContent` sweep in `mcp_structured_output_test.exs` both gate every push, and the sweep fails if a tool advertises a schema it does not honour. Regression protection lives there; the conformance suite's job is the third-party-client signal.

**Do not excuse a gap using a spec revision you do not serve.** `ping` was once left unimplemented because `2026-07-28` removes it, but it is a base-protocol MUST in every revision we serve (fixed in #1680).

**Gotcha: the CLI writes advisories to STDOUT, ahead of the JSON.** `json.load` on the raw capture therefore fails and the run reports NO SIGNAL — a harness fault wearing a server verdict's clothes. `scripts/lib/report_io.py` locates the document and keeps the preamble (it often explains the failures beneath it). Redirecting stderr does not help; these are stdout.

## Still open: completing the flow past consent

`e2e/tests/api_only/test_71_connections.py` already drives the whole OAuth flow headlessly (consent approved with a Clerk JWT, no browser). Driving the CLI with `--auth-mode interactive --print-url` and approving the emitted URL the same way would un-skip `token_request`, `received_tokens`, `authenticated_mcp_request`, and restore the `--conformance-checks` negative checks, which have never run. Make sure the fingerprint does not skip it for OAuth-relevant diffs.

## Related
- `docs/context/cimd-vs-dcr-validation-policy.md` — why DCR and CIMD validate differently
- `docs/context/oauth-discovery-urls-behind-edge-tls.md`: host/port/proxy failures for a client that cannot connect at all
- engram-app/Engram#1633, #1634, #1635 (closed): the ChatGPT `private_key_jwt` refusal and the one-vendor coverage gap

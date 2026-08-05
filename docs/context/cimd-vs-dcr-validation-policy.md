# CIMD documents are negotiated, DCR registrations are policed — don't share the changeset

_Last verified: 2026-08-04_

Root cause of the 2026-08-04 prod outage where **every Claude connect died on `invalid_client`**. Fix in `fix/cimd-spec-validation`. Related: [[connections-client-identity]], [[mcp-oauth]].

## Symptom

User adds the connector in Claude (Desktop/web/mobile/Code), gets our own error page:

```
Authorization error
Error: invalid_client.
The OAuth client or redirect URI is not recognized. The request was rejected to prevent code-leak attacks.
```

That copy is **ours** — `oauth_authorize_controller.ex` `render_client_error/2`. It is not a claude.ai page. Seeing it means `OAuth.validate_authorization_request/1` returned `{:client_error, "invalid_client"}`.

Prod log signature (Loki, `{service_name="engram", env="prod"}`):

```
mcp_cimd_rejected  host=claude.ai  reason=:invalid_document
GET 400            route=EngramWeb.OAuthAuthorizeController#show
```

Both lines share a `trace` + `request_id`. That pairing is how you confirm the 400 *is* the CIMD rejection rather than a coincidence.

## Why it started (the part that surprises people)

Nothing in the DCR path broke. **Claude stopped using DCR.**

Anthropic's clients select CIMD when — and only when — the authorization-server metadata advertises *both*:

```json
"client_id_metadata_document_supported": true,
"token_endpoint_auth_methods_supported": ["none", ...]
```

PR #1167 turned the first one on. From that deploy onward every Claude surface sent a `claude.ai` URL as `client_id` instead of registering. A one-word change to a `/.well-known/` document silently repointed every client at a code path that had never carried real traffic.

**Rule: a change to a discovery document is a client-behaviour change, not a config change.** Treat it like a deploy of the code path it enables.

## The actual bug

`Cimd.store/3` validated a fetched vendor document by calling `Client.registration_changeset/2` — the **DCR registration policy**. A prior test even defended this as DRY ("a CIMD-specific validation path would be a second copy of those rules").

Half right. Two different questions were sharing one answer:

| | DCR (`POST /oauth/register`) | CIMD (fetched document) |
|---|---|---|
| Who is speaking | an anonymous stranger asking permission | a vendor describing itself to *every* AS on the internet |
| Unknown `grant_types` | reject — they can fix and retry | **intersect** — they weren't asking us |
| Bad `logo_uri` | reject | **drop the field** — a logo must not cost a connector |
| Over-long `client_name` | reject | **truncate** |
| Unsafe `redirect_uri` | reject | **reject** — code-leak vector, not a capability |

Applying registration policy to a published document means any metadata we happen not to implement kills the whole authorization. RFC 7591 §3.2.1 says the opposite: the AS records what *it* supports and reports back what it granted.

The likeliest concrete trigger: Anthropic's hosted document declaring a `urn:ietf:params:oauth:grant-type:*` entry (Enterprise Managed Auth does token exchange), tripping `validate_subset(:grant_types, ~w(authorization_code refresh_token))`.

**The fix is the split, not a longer allowlist.** Widening the subset list would have worked until the next field. `Cimd.negotiate/1` now intersects capability metadata and drops decoration *before* the changeset; safety rules (redirect URIs, the self-referential `client_id` binding, confidential-method refusal) stay shared and still refuse.

## Two things that made it undiagnosable

Both cost more investigation time than the bug itself.

**1. `:invalid_document` collapsed two unrelated failures** — a changeset refusal and a lost insert race — and discarded the changeset errors. The log named the host and nothing else, so it could not say *which field* died. Now: `{:invalid_document, errors}` vs `:store_conflict`, and the log carries `fields=[...]`.

> Log the field **names**, never the changeset messages. Several messages interpolate the offending value (`"missing scheme: #{uri}"`), which is attacker-supplied on an unauthenticated endpoint — the same reason `cimd_host` is a host and not the full URL.

**2. Every CIMD failure was reported as `invalid_client`,** including `:rate_limited`, `:fetch_failed`, 5xx from the vendor, and the lost race. Two consequences, and the second is nasty:

- `invalid_client` is *terminal*. Clients stop retrying; users see a permanently dead connector.
- `:rate_limited` is **deliberately never logged** (unbounded log volume behind a bounded side effect — the argument in `Cimd`'s moduledoc is sound). So once the first store failed, no row existed, *every* retry re-entered discovery and burned the 10/min per-host bucket **silently**.

Net effect: one log line, many user-visible failures. If you ever see a single `mcp_cimd_rejected` and a user reporting persistent failure, **assume the retries were absorbed by the limiter** — absence of logs is not absence of attempts.

`OAuth.cimd_error/1` now splits transient (→ `{:server_error, "temporarily_unavailable"}`, HTTP 503, distinct page) from terminal (→ `invalid_client`).

## Reproducing without a Claude client

The whole flow is a plain GET. Claude Code's real document is public:

```bash
curl -s https://claude.ai/oauth/claude-code-client-metadata
# {"client_id":"https://claude.ai/oauth/claude-code-client-metadata","client_name":"Claude Code",
#  "redirect_uris":["http://localhost/callback","http://127.0.0.1/callback"], ...}

CID=$(python3 -c "import urllib.parse;print(urllib.parse.quote('https://claude.ai/oauth/claude-code-client-metadata',safe=''))")
RU=$(python3 -c "import urllib.parse;print(urllib.parse.quote('http://localhost:3118/callback',safe=''))")
curl -si "https://mcp.engram.page/oauth/authorize?response_type=code&client_id=$CID&redirect_uri=$RU\
&code_challenge=E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM&code_challenge_method=S256&scope=mcp&state=probe"
# 302 → app.engram.page/oauth/consent?...   = healthy
```

Note the **portless** `redirect_uris` in that document against a **ported** runtime redirect. Our RFC 8252 §7.3 loopback port exemption (`OAuth.loopback_port_match?/2`) is what makes that work — it is load-bearing for every local-first connector, not a nicety.

To test validation logic without booting the app or a DB:

```bash
mix run --no-start /path/to/probe.exs   # changeset validation is pure
```

## Dead ends (don't repeat these)

- **Guessing the failing URL from claude.ai paths.** Only `/oauth/claude-code-client-metadata` is publicly readable; other `/oauth/*` paths return a Cloudflare challenge to curl. The hosted-surface CIMD URL is undocumented. You cannot recover it from our logs either — `request_query` is redacted and `cimd_host` is host-only, both on purpose.
- **Assuming the changeset must be rejecting a malformed document.** The live Claude Code document passes `cimd_changeset` cleanly, and so do the obvious hosted-surface shapes. Verify before theorising.
- **Reproducing the insert race on staging.** Six concurrent cold-cache authorizes all 302. Staging is single-container; under READ COMMITTED the losing insert blocks until the winner commits and then finds the row, so the race branch is genuinely hard to hit.

## The regression net that actually catches this class

Two things, both drawn from outside our own head.

**1. Real published documents as fixtures.** `cimd_test.exs` now pins the live
Claude Code document *and* MCPJam's. The second is the valuable one: it declares
`urn:ietf:params:oauth:grant-type:device_code` and lists **14** redirect URIs, so
against pre-fix code it failed twice over (`contains an unsupported grant_type`
and `should have at most 10 item(s)`). Fetch them again if they start failing;
do not edit them to fit.

That second failure is worth dwelling on. During review I noticed the 10-URI cap
was DCR policy sitting in the safety bucket, reasoned that "Claude publishes two,
revisit if a real document approaches it", and left it. A real document blew past
it about ten minutes later. The cap is now per-path: 10 for DCR (anonymous POST,
anti-abuse), 50 for CIMD (already bounded by the fetcher's mid-stream body cap).

**2. `scripts/mcp-conformance.sh`** — MCPJam's OAuth conformance CLI, run daily
against staging by the `mcp-conformance` job in `cron.yml`. It performs the real
handshakes Claude Desktop/Code and ChatGPT perform. Against pre-fix main:

```
==> dcr  reached the consent gate cleanly (10 steps passed)
==> cimd REGRESSION: received_authorization_code [HTTP 400]
```

### Two traps in that script, both already paid for

**Judge the HTTP status, not the step name.** The first version of the classifier
excused `received_authorization_code` as "consent-gated" and therefore reported
**green against a server we knew was broken**. Our authorization endpoint needs a
Clerk session, so that step fails on a healthy server too — but healthy fails
*after* a `302` to consent, and broken fails *with a* `400`. Same step name, and
only the status separates them. Anything ≥400 is a regression no matter which
step reports it.

**It belongs in `cron.yml`, not `verify.yml`.** It grades a running deployment.
On a PR the deployment still runs `main`, so a per-PR job would grade the wrong
code and be reliably, meaninglessly green.

Pin the CLI version. The npm package carries registry signatures but **no build
provenance attestation**, so the tarball is not cryptographically tied to a
commit, and `@latest` would give a compromised publish network access to our
authorization server from CI. It also bundles `posthog-node` and is telemetry-
opt-out rather than opt-in — hence `--no-telemetry`.

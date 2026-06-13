# Trustworthy client-IP rate limiting

_Design — 2026-06-13_

## Problem

Both IP-keyed rate limiters key on `conn.remote_ip`:

- `EngramWeb.Plugs.RateLimit` (10 req / 60 s) on the pre-auth pipelines: `/oauth/{register,token,revoke,authorize}`, `/api/auth/{device,login,register,refresh}`, `/api/oauth/clients/:id`.
- `EngramWeb.Plugs.NotesRateLimit` (600 req / 60 s, `{ip, sub-or-anon}` bucket) on the vault-scoped pipeline.

In prod the request path is **Cloudflare → AWS ALB → ECS (Bandit)**. Bandit's TCP peer is the ALB, so `conn.remote_ip` is the ALB's private IP — **identical for every external client**. Consequences:

1. **HIGH — auth-DoS / no brute-force isolation.** The 10/60 s auth bucket collapses to a near-global cap. One host doing 10 req/min on `/api/auth/login` locks *all* users out of login / device pairing / token exchange. Credential-stuffing is no longer per-attacker.
2. **MED — coverage gap.** `NotesRateLimit` only fires on `/api/notes/*` (internal `String.starts_with?` guard), yet it is mounted on a pipeline that also serves `/api/search`, `/api/folders`, `/api/tags`, `/api/attachments`, `/api/logs`, `/api/mcp`. Those paths pass through the plug but it no-ops — unthrottled 401-loop surface.

## Why the obvious fix is wrong

Mounting `Plug.RewriteOn` / blindly trusting `X-Forwarded-For` re-opens a bypass: XFF is client-appended and spoofable. The standard mitigation is to trust forwarded headers **only from a verified proxy**.

## Key infra fact

Prod enforces **Cloudflare Authenticated Origin Pulls (AOP) in `verify` mode** (`engram-infra main/envs/prod/aop.tf`, `alb.tf:105`): the ALB rejects any TLS handshake lacking a valid Cloudflare-signed client cert. So **every request reaching ECS provably transited Cloudflare**, even though the ALB security group is `0.0.0.0/0` (`security_groups.tf`). This transport-layer gate is *stronger* than an IP allowlist and removes any need to maintain Cloudflare CIDR lists.

Cloudflare always **overwrites** `CF-Connecting-IP` with the true client IP (unspoofable through CF, unlike XFF which it appends). The ALB passes request headers through unchanged. So when AOP is on, `CF-Connecting-IP` is the authoritative client IP.

## Design

### 1. `EngramWeb.RemoteIp.resolve/1` (new, single-purpose)

```
resolve(conn) :: :inet.ip_address()
  if Application.get_env(:engram, :trust_cf_connecting_ip, false):
    case first "cf-connecting-ip" header parses as a valid IP -> that IP
    else -> conn.remote_ip            # missing / malformed -> fail safe
  else:
    conn.remote_ip
```

Pure and unit-testable. A module comment documents the **AOP coupling**: trusting the header is only safe because AOP `verify` guarantees Cloudflare transit; if AOP is ever disabled or set to `passthrough`, `CF-Connecting-IP` becomes spoofable and this flag MUST be off.

### 2. Config — default-deny

- `config/config.exs`: `config :engram, trust_cf_connecting_ip: false`. Dev, test, self-host (`engram.ax`), and staging-fastraid keep current behavior (raw socket IP) — those topologies are not Cloudflare+AOP.
- `config/runtime.exs` prod branch: `trust_cf_connecting_ip: System.get_env("TRUST_CF_CONNECTING_IP") == "true"` (default false).
- **Backend merge alone changes nothing in prod.** The flag flips only when infra sets the env. Fail-safe direction: a missing/misconfigured flag over-limits (raw IP) rather than opening a bypass.

### 3. Both plugs call `RemoteIp.resolve/1`

`RateLimit.rate_limit_key/1` and the renamed limiter's `bucket_key/1` swap `conn.remote_ip` → `EngramWeb.RemoteIp.resolve(conn)`. Fixes #1 for both limiters.

### 4. Rename `NotesRateLimit` → `PreAuthRateLimit`, drop the path guard (#2)

The plug is mounted on exactly one pipeline (the vault-scoped one); every route there should be pre-auth-limited. Remove the `@path_prefix "/api/notes"` filter so the plug protects its whole pipeline, and a future route added there is covered by default instead of silently skipped. The `{ip, sub-or-anon}` bucket key and 600/60 s default are unchanged. Rename because a plug named `NotesRateLimit` that limits everything is a footgun; update the module, the `router.ex` `pipe_through`, the moduledoc, and the test module name.

## Out of scope (separate follow-ups)

- `RATE_LIMIT_AUTH_OVERRIDE` honored in prod on env-var presence (finding #6, low).
- Per-plan RPS-budget tuning.

## Cross-repo follow-up

One-line **engram-infra** PR: set `TRUST_CF_CONNECTING_IP=true` in the prod ECS task definition (justified by AOP being on). Applied by the operator when ready; the backend default keeps prod on raw-IP until then.

## Testing (TDD)

- `RemoteIp`: flag off → socket IP; flag on + valid header → header IP; flag on + missing/garbage header → socket fallback; flag on + multi-value header → first valid.
- Limiter: existing `RateLimitTest` and notes-limiter tests stay green; new test proves a non-`/api/notes` vault path (e.g. `/api/search`) is bucketed pre-auth.
- Full `mix test`.

# Context Doc: OAuth discovery URLs behind edge-terminated TLS

_Last verified: 2026-08-05_

## Status

Fixed. `EngramWeb.OAuthMetadata.with_port/2` now treats **both** 80 and 443 as "no port".
The bug never reached prod — it was caught on staging while prod still ran
`release-v0.13.0`.

## The symptom

Staging advertised an authorization server nothing could dial:

```json
{"issuer":"https://staging.engram.page:80",
 "token_endpoint":"https://staging.engram.page:80/oauth/token",
 "resource":"https://staging.engram.page:80/api/mcp"}
```

```
$ curl -X POST https://staging.engram.page:80/oauth/token
TLS connect error: error:0A00010B:SSL routines::wrong version number
```

Not a cosmetic mismatch. `https://…:80` is a TLS handshake against a plaintext port, so
every client following the advertised endpoints fails at connect. The RFC 9728 §5.1
`WWW-Authenticate` challenge carried the same `:80`, so discovery dead-ended too.

## Root cause

`base_url/1` derived the scheme and the port from two different sources:

```elixir
scheme = URI.parse(canonical).scheme    # "https" — from PHX_HOST
with_port(candidate, scheme, conn.port) # 80      — from the connection
```

`conn.port` is not "the port the client dialed". When the Host header carries no port —
the norm — the adapter substitutes the default for the scheme the **socket** arrived on.
Our chain is Cloudflare → ALB → Bandit **over plain HTTP**, so
`bandit/lib/bandit/pipeline.ex` fills in `URI.default_port("http")` = 80 while the public
scheme is https. Judged against the https default, 80 looks like a real dialed port.

The fix is to treat **both** 80 and 443 as "no port". Gating on the *connection's* scheme
instead of the advertised one fixes this case but breaks its mirror — a proxy forwarding
`Host: host:443` over a plaintext hop, where 443 is not http's default and would get
echoed into `https://host:443`. Since 80 and 443 are the defaults for the only two schemes
we serve, no real deployment needs either in its URL, so neither is ever a "real" port.
Anything else is preserved (self-host on `:8080`, port-mapped container, reverse proxy on
`:8443`, loopback CI stack on `:4000`) — which is what the port logic was added for in
#1260.

> Worth noting the general shape: the first fix attempt swapped *which* single scheme the
> port was judged against, which trades one failing configuration for another. Any rule of
> the form "compare an edge-supplied value against one config-supplied value" has this
> mirror-case hazard.

## Why every gate was green

The failing cell is **https canonical scheme + plaintext connection**. No test environment
has it:

- **Unit suite** — `config/test.exs` runs the endpoint on plain http, so the canonical
  scheme matches the socket. `well_known_host_test.exs` even asserted `port: 80` is
  omitted, and passed, because there `with_port(base, "http", 80)` hit the elision clause.
- **Per-PR conformance gate** (`CONFORMANCE_STAGES=spec` against the CI stack) — the client
  genuinely dials `localhost:4000`, so the port genuinely belongs in the URL.
- **Nightly conformance** against staging *would* have caught it (its `case "$advertised"`
  accepts only `$TARGET_URL` or `$ORIGIN`), but it runs 05:40 UTC and the change merged at
  10:12 UTC.

Reproducing it in a test means moving the canonical URL, which Phoenix caches in ETS at
boot — `Application.put_env` alone does not move `Endpoint.url/0`:

```elixir
Application.put_env(:engram, EngramWeb.Endpoint, config)
EngramWeb.Endpoint.config_change([{EngramWeb.Endpoint, config}], [])
```

## Staging does not cover prod's host behavior

`ENGRAM_HOST_REWRITE_ENABLED` is set **only in prod** (`engram-infra main/envs/prod/ecs.tf`).
Staging's own metadata proves it: staging advertises the path form
`https://staging.engram.page/api/mcp`, prod the bare form `https://mcp.engram.page`, and
that fork is `OAuthMetadata.mcp_rewrite_host?/1` reading `:host_rewrite`.

So these are dark on staging and unexercised by any deployed test:

- the bare-root `resource` and `resource_metadata_url` branches
- `HostRewrite`'s `/oauth` and `/.well-known/oauth-*` passthrough on the MCP host
- `reject_unknown_hosts` (`ENGRAM_SAAS_ONLY=true`) returning 410
- the cross-origin consent redirect (`ENGRAM_FRONTEND_URL=https://app.engram.page`;
  staging is same-origin)

**A green staging is not evidence for those.** Run the conformance script against
`https://mcp.engram.page` after a deploy — the script accepts `$ORIGIN` as the advertised
resource, so the bare form passes there.

## Checked and fine on prod's topology

Ruled out while hunting this, worth not re-deriving:

- **Cloudflare does not cache discovery** — `cf-cache-status: DYNAMIC`,
  `cache-control: max-age=0, private, must-revalidate`. A fix takes effect immediately, no
  purge step.
- **The consent round-trip survives HostRewrite.** SPA on `app.engram.page` →
  `api.engram.page/oauth/authorize/consent`; `oauth` is in `@api_top_segments`, so it
  rewrites to `/api/oauth/authorize/consent`, which exists. `fetchOAuthClient` already
  hardcodes the `/api` prefix.
- **The RFC 8707 `resource` param is never server-validated** —
  `oauth_authorize_controller.ex` only forwards it to the SPA. The `:80` bug therefore did
  not additionally poison token exchange.
- **CIMD egress** is ordinary outbound HTTPS through NAT, same path as Voyage/Qdrant/
  Clerk/Paddle. `SsrfGuard` pins to a resolved public address; no proxy interaction.

## Gotchas

- **Never pipe the conformance script.** `scripts/mcp-conformance.sh … | tail` reports
  `tail`'s exit code — it printed `SPEC VIOLATION` and exited 0 through a pipe, 1 without.
- `resource_documentation` advertises `<base>/docs`, which **404s on the MCP host** —
  `HostRewrite` admits only `/api/mcp`, `/oauth`, and `/.well-known/oauth-*`.
- Clients that dial the path form `https://mcp.engram.page/api/mcp` (still in older docs)
  get `resource = https://mcp.engram.page` and can self-check-mismatch. The conformance
  script accepts either, which hides it; point it at the path form deliberately to see.

## References

- `lib/engram_web/oauth_metadata.ex` (`with_port/2`), `test/engram_web/controllers/well_known_host_test.exs`
  ("TLS terminated at the edge")
- `lib/engram_web/plugs/host_rewrite.ex`, `lib/engram_web/plugs/mcp_auth_challenge.ex`
- `scripts/mcp-conformance.sh`, `.github/workflows/cron.yml` (`mcp-conformance`)
- Introduced by #1260, alongside #1255 (RFC 9728 compliance) and #1241 (CIMD)
- Related: `docs/context/cimd-vs-dcr-validation-policy.md`,
  workspace `docs/context/public-url-host-split.md`

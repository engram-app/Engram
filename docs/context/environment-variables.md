# Context Doc: Environment Variables

_Last verified: 2026-06-18 (regenerated from `config/runtime.exs`)_

## Status
Live. This is regenerated from `config/runtime.exs` (the ~90 vars it reads), with compile-time defaults pulled from `config/config.exs`, `config/dev.exs`, `config/test.exs`. Line numbers cite `config/runtime.exs` unless noted.

## How runtime.exs is shaped (read this first)

- **`APP_SECRETS_JSON`** (runtime.exs:9-12) — prod ships ALL app secrets as one SSM SecureString blob (one KMS decrypt). `Engram.Secrets.unpack/2` expands it into the process env *before* every `System.get_env` below, so the individual var names still resolve. Self-host/dev leave it unset (no-op). Malformed JSON fails boot loudly. See `docs/context/kms-secret-consolidation` work.
- **Auth shape switch:** `AUTH_PROVIDER` (default `local`, runtime.exs:174) selects self-host (built-in email/password) vs SaaS (`clerk`). Many vars below are required *only* when `clerk`.
- **Billing gate:** `billing_enabled` is derived — `auth_provider == :clerk and PADDLE_API_KEY != nil` (runtime.exs:403-405). Self-host (or SaaS without a Paddle key) short-circuits the onboarding wizard.
- **Test guard:** blocks gated on `config_env() != :test` (storage, embedder, email, Paddle, key provider) so a developer's exported shell vars can't flip `mix test` onto real adapters.

---

## Core / Endpoint

| Variable | Default | Purpose |
|----------|---------|---------|
| `APP_SECRETS_JSON` | unset | Prod-only bundled-secrets blob, unpacked into env at boot (runtime.exs:9). |
| `PHX_SERVER` | unset | Start the Phoenix server in a release (`bin/engram start`) (:30). |
| `PORT` | `4000` | HTTP listen port (:35). |
| `PHX_HOST` | unset (`localhost` for URLs in dev) | Canonical host(s) for URL gen + CORS/WS origin. **Comma-separated; first entry is canonical** (:508). When unset, CORS allows `*` and WS allows all (fine for self-host; a SaaS deploy fails closed if `PHX_HOST` is missing — :653). |
| `PHX_SCHEME` | `https` prod / `http` dev | URL scheme (:511). |
| `PHX_PORT` | `443` prod / `80` dev | URL port for generated links (:515). |
| `DATABASE_URL` | — (required in prod, :558) | `ecto://USER:PASS@HOST/DATABASE`. |
| `POOL_SIZE` | `10` | Ecto pool size (:582). |
| `ECTO_IPV6` | unset | `true`/`1` → connect to Postgres over IPv6 (:564). |
| `DATABASE_SSL` | off | `true` enables TLS to Postgres (required by AWS RDS) (:575, via `RuntimeConfig.database_ssl/2`). |
| `DATABASE_SSL_MODE` | `verify_none` | `verify-full` → `verify_peer` w/ OS trust store + SNI + hostname check (:570). |
| `SECRET_KEY_BASE` | — (required in prod, :597) | Phoenix cookie/secret signing. |
| `JWT_SECRET` | — (required in prod, :604) | Joken default signer for internal JWTs (:610). |
| `DNS_CLUSTER_QUERY` | unset | libcluster DNS query for BEAM node discovery (:612). When set, the rate limiter auto-selects the distributed ETS + Phoenix.PubSub backend; unset → plain ETS. |

> `RELEASE_COOKIE` is consumed by the Elixir release runtime (`rel/`/`mix release`), not read in `runtime.exs`.

## Frontend / Hosts / CORS

| Variable | Default | Purpose |
|----------|---------|---------|
| `ENGRAM_SAAS_FRONTEND_ORIGINS` | unset | Extra CORS/WS origins (comma-sep) for the Cloudflare Pages SPA + preview deploys (:661). |
| `ENGRAM_HOST_REWRITE_ENABLED` | unset (`false`) | `true` enables `HostRewrite` plug for the dedicated `api.`/`mcp.engram.page` hosts. Self-host + current `app.` leave unset → strict no-op (:684). |
| `ENGRAM_SAAS_ONLY` | unset | `true` → `reject_unknown_hosts` in HostRewrite (:685). |
| `ENGRAM_HOST_REWRITE_API_HOST` | `api.engram.page` | API host for path rewrite (:695). |
| `ENGRAM_HOST_REWRITE_MCP_HOST` | `mcp.engram.page` | MCP host for path rewrite (:696). |
| `ENGRAM_ALLOWED_EXTRA_HOSTS` | unset | Comma-sep extra allowed hosts (:688). |
| `ENGRAM_FRONTEND_URL` | unset | Absolute SPA base URL for cross-origin OAuth `/authorize` 302 (post-eject) (:706). |
| `ENGRAM_UPGRADE_URL` | `https://app.engram.page/settings/billing` | Upgrade URL surfaced in 402 limit-exceeded responses (:198-200). |
| `TRUST_CF_CONNECTING_IP` | `false` | Prod-only: trust `CF-Connecting-IP` for rate-limit client IP. Safe only under Cloudflare AOP `verify` (:534). |

## Storage / Attachments

> **`STORAGE_BACKEND` code default is `s3`** (runtime.exs:44 — `System.get_env("STORAGE_BACKEND", "s3")`). `s3` is the SaaS/prod (AWS S3) and standard self-host (MinIO) path. `database` (#297) is a self-host-only convenience that stores opaque ciphertext in the generic `storage_objects` table (NOT the removed `attachments.content` column). Unknown values raise at boot (:77).

| Variable | Default | Purpose |
|----------|---------|---------|
| `STORAGE_BACKEND` | `s3` | `s3` or `database` (:44). |
| `STORAGE_BUCKET` | `engram-attachments` | S3 bucket (:47). |
| `STORAGE_ACCESS_KEY_ID` | unset | Static S3 key (MinIO/non-AWS). Leave unset on ECS to use the task role (:53). |
| `STORAGE_SECRET_ACCESS_KEY` | — | Paired secret (required if access key set, :55). |
| `STORAGE_REGION` | `auto` (falls back to `AWS_REGION`, then `us-east-1`) | S3 region (:57, :60). |
| `STORAGE_HOST` | unset | Endpoint host override for MinIO / non-AWS S3 (:66). |
| `STORAGE_SCHEME` | `https://` | Used only when `STORAGE_HOST` set (:68). |
| `STORAGE_PORT` | `443` | Used only when `STORAGE_HOST` set (:70). |

## Embedding (Voyage / Ollama)

> Embedder default is `voyage` (runtime.exs:85 — `EMBED_BACKEND` defaults to `voyage`). `ollama` selects the self-host adapter.

| Variable | Default | Purpose |
|----------|---------|---------|
| `EMBED_BACKEND` | `voyage` | `voyage` or `ollama` (:85). |
| `VOYAGE_API_KEY` | unset | Voyage AI key (used when backend = voyage) (:92). |
| `EMBED_MODEL` | (compile-time) | Override symmetric embed model (:97). |
| `EMBED_DIMS` | (compile-time) | Override vector dimensions (:101). |
| `DOC_EMBED_MODEL` | falls back to `EMBED_MODEL` | Asymmetric: doc-indexing model (:107). |
| `QUERY_EMBED_MODEL` | falls back to `EMBED_MODEL` | Asymmetric: query model (:111). |
| `EMBED_429_SNOOZE_SECONDS` | `60` | Voyage-429 snooze (worker reschedules without burning an attempt) (:118). |
| `VOYAGE_RPM` | unset (no throttle) | Client-side cap — synthetic 429 before real call (:131). |
| `VOYAGE_QUERY_RPM` | falls back to `VOYAGE_RPM` | Separate bucket for synchronous search (:135). |
| `OLLAMA_URL` | (adapter default `http://localhost:11434`) | Ollama server (self-host). |

## Vector DB (Qdrant)

> **`QDRANT_COLLECTION` — nuance.** `runtime.exs` only sets the config when the env var is present (:143-145). The *fallback if unset* differs by source: dev/test config pin `engram_notes` (`config/dev.exs:78`, `config/test.exs:71`), but the module-level `Application.get_env(:engram, :qdrant_collection, "obsidian_notes")` fallback is **`obsidian_notes`** (`lib/engram/indexing.ex:20`, `lib/engram/search.ex:16`). In prod the collection comes from the `QDRANT_COLLECTION` env var; the live prod collection is **`engram_notes`** (set explicitly). Net: never rely on the implicit fallback in prod — set `QDRANT_COLLECTION` explicitly.

| Variable | Default | Purpose |
|----------|---------|---------|
| `QDRANT_URL` | (compile-time) | Qdrant base URL (:139). |
| `QDRANT_COLLECTION` | env-driven; fallback `obsidian_notes` (module) / `engram_notes` (dev+test+prod) | Collection name (:143). See nuance above. |
| `QDRANT_API_KEY` | unset | Qdrant Cloud key (:147). |
| `QDRANT_BINARY_QUANTIZATION` | on | Set `false` to disable BQ on non-AVX2 hardware (:152). |

## Search / Reranker

| Variable | Default | Purpose |
|----------|---------|---------|
| `RERANKER_BACKEND` | `none` | `jina` or `none` (:157). |
| `JINA_URL` | — (required when `RERANKER_BACKEND=jina`) | Reranker URL (:163). |

## Auth (local / Clerk)

| Variable | Default | Purpose |
|----------|---------|---------|
| `AUTH_PROVIDER` | `local` | `local` (built-in email/password) or `clerk` (SaaS JWKS) (:174). |
| `ENGRAM_DEFAULT_REGISTRATION_MODE` | `invite_only` | Self-host registration default: `closed` / `invite_only` / `open` (:186). |
| `CLERK_JWKS_URL` | — (required if clerk, :277) | Clerk JWKS endpoint. |
| `CLERK_ISSUER` | — (required if clerk, :284) | Clerk issuer. |
| `CLERK_PUBLISHABLE_KEY` | — (required if clerk, :290) | Clerk publishable key. |
| `CLERK_SECRET_KEY` | unset | Backend API key (`sk_*`) — revoke duplicate signups (pricing v2 §A) (:300). |
| `CLERK_WEBHOOK_SECRET` | unset | Verifies inbound svix signatures (`whsec_*`) (:304). |
| `CLERK_AUTHORIZED_PARTIES` | unset (passthrough) | Comma-sep `azp` allowlist (:313). |
| `CLERK_WAITLIST_MODE` | unset | `1`/`true` → SPA waitlist UI (mirror the Clerk dashboard) (:333). |

## Encryption / Key Provider

| Variable | Default | Purpose |
|----------|---------|---------|
| `KEY_PROVIDER` | `local` | `local` or `aws_kms` (:454). |
| `ENCRYPTION_MASTER_KEY` | unset | Master key for wrapping per-user DEKs (local provider) (:462). |
| `ENCRYPTION_MASTER_KEY_PREVIOUS` | unset | Old master key during rotation (:463). |
| `ENCRYPTION_MASTER_KEY_VERSION` | `1` | Master key version (:465). |
| `DEK_CACHE_TTL_MS` | `3600000` (1h) | DEK cache TTL (:466). |
| `BOOT_CANARY_ENABLED` | on | `false` disables the boot canary during master-key rotation window (:476). See `encryption-operations.md`. |
| `AWS_KMS_KEY_ID` | — (required if `KEY_PROVIDER=aws_kms`, :483) | KMS CMK id. |
| `AWS_REGION` | — (required for KMS; also S3 region fallback) | AWS region (:484). |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | unset | Static KMS creds; unset on ECS → task role (:494). |

## Email (Resend)

> Default provider is NoOp; Resend activates when `RESEND_API_KEY` is set (non-test only) (:214).

| Variable | Default | Purpose |
|----------|---------|---------|
| `RESEND_API_KEY` | unset | Activates `Engram.Email.Resend` (:215). |
| `EMAIL_FROM` | unset | From-address override (:220). |
| `RESEND_WEBHOOK_SECRET` | unset | `whsec_*` for `POST /webhooks/resend` (bounce/complaint). Unset → endpoint rejects all events (:227). |

## Billing (Paddle — MoR)

Paddle is the Merchant-of-Record. Server keys gate API calls; the client token feeds the Paddle.js overlay; price IDs are **split monthly/annual per tier** (not a single `PADDLE_<TIER>_PRICE_ID`). See `docs/context/paddle-integration.md`. All Paddle config is non-test-only (:368).

| Variable | Default | Purpose |
|----------|---------|---------|
| `PADDLE_ENV` | `sandbox` | `sandbox` or `production` (:397). |
| `PADDLE_API_KEY` | unset | Server-side key; also gates `billing_enabled` (:369). |
| `PADDLE_NOTIFICATION_SECRET` | unset | Webhook signing secret (:373). |
| `PADDLE_CLIENT_TOKEN` | unset | Public token for the overlay (:377). |
| `PADDLE_STARTER_MONTHLY_PRICE_ID` | unset | Starter monthly `pri_*` (:382). |
| `PADDLE_STARTER_ANNUAL_PRICE_ID` | unset | Starter annual `pri_*` (:386). |
| `PADDLE_PRO_MONTHLY_PRICE_ID` | unset | Pro monthly `pri_*` (:390). |
| `PADDLE_PRO_ANNUAL_PRICE_ID` | unset | Pro annual `pri_*` (:393). |

## Limits & Plan Enforcement

> Per-tier numeric limits are NOT individual env vars anymore. They are defined by `Engram.Billing.LimitKeys` and overridden via generated `ENGRAM_<TIER>_<KEY>` env vars parsed at boot (:436-445). Bad values fail boot. Old knobs `REGISTRATION_ENABLED`, `MAX_ATTACHMENT_SIZE`, `MAX_STORAGE_PER_USER`, `MAX_NOTE_SIZE`, `RATE_LIMIT_RPM` are **gone** — migrated to LimitKeys.

| Variable | Default | Purpose |
|----------|---------|---------|
| `ENGRAM_LIMITS_ENFORCED` | derived (`clerk` + Paddle key) | `true`/`false` override of plan-limit enforcement (:414). |
| `ENGRAM_<TIER>_<KEY>` | unset | Per-tier limit overrides (e.g. `ENGRAM_FREE_MAX_NOTES`); names come from `LimitKeys.env_var_names/0` (:437). |
| `REQUIRE_PHONE_FOR_EMBED` | off | Pricing v2 §A phone-verification gate on EmbedNote (:341). |
| `ATTACHMENT_MIME_BYPASS` | off (gate ON) | `true` disables the MIME/extension whitelist (:351). |
| `ATTACHMENT_MIME_ALLOWLIST_EXTRA` | unset | Comma-sep extra allowed MIMEs without disabling the gate (:355). |
| `RATE_LIMIT_AUTH_OVERRIDE` | ignored unless `CI=true` | Auth-limiter override for CI/E2E only (:236). |
| `PRE_AUTH_RATE_LIMIT_OVERRIDE` | ignored unless `CI=true` | Pre-auth (vault-pipeline) limiter override for CI/E2E only (:257). |
| `CI` | unset | `true` unlocks the two rate-limit overrides above (:236). |

## Observability (Sentry / PostHog / Pyroscope / Metrics)

Each block is opt-in: unset → no-op (dev/test/self-host emit nothing).

| Variable | Default | Purpose |
|----------|---------|---------|
| `METRICS_AUTH_TOKEN` | unset | Bearer guarding the PromEx `/metrics` scrape. Unset → `MetricsAuth` plug fails closed (endpoint disabled) (:748). |
| `SENTRY_DSN` | unset | Sentry error tracking (:757). |
| `RELEASE_SHA` | unset | Sentry release tag — must match `getsentry/action-release` (:770). |
| `POSTHOG_API_KEY` | unset | Server-side PostHog capture (:794). |
| `POSTHOG_HOST` | `https://us.i.posthog.com` | PostHog ingest host (:797). |
| `GRAFANA_PYROSCOPE_URL` | unset | Enables continuous CPU profiling (:812). |
| `GRAFANA_PYROSCOPE_USERNAME` | — (required if Pyroscope URL set, :817) | Pyroscope username. |
| `GRAFANA_AGENT_TOKEN` | — (required if Pyroscope URL set, :819) | Shared Grafana Cloud token (metrics/logs/traces/profiles write). |
| `PYROSCOPE_APP_NAME` | `engram-saas-prod` | Pyroscope app label (:821). |
| `HOSTNAME` / `ECS_TASK_ID` | `unknown` | Pyroscope instance label (:823). |

## Notes on removed / migrated vars

- `REGISTRATION_ENABLED` → replaced by `ENGRAM_DEFAULT_REGISTRATION_MODE` + `Engram.Instance.registration_mode/0`.
- `MAX_ATTACHMENT_SIZE`, `MAX_STORAGE_PER_USER`, `MAX_NOTE_SIZE`, `RATE_LIMIT_RPM` → moved into `Engram.Billing.LimitKeys` (per-tier; override via `ENGRAM_<TIER>_<KEY>`).
- Legal version/hash env vars → dropped; legal docs now live in the `terms_versions` table seeded from `priv/legal/legal-manifest.json` (:448).

## References
- Runtime config (source of truth): `config/runtime.exs`
- Compile-time defaults: `config/config.exs`, `config/dev.exs`, `config/test.exs`
- Module-level Qdrant collection fallback: `lib/engram/indexing.ex:20`, `lib/engram/search.ex:16`
- Limit keys: `Engram.Billing.LimitKeys`
- Paddle: `docs/context/paddle-integration.md`
- Encryption: `docs/context/encryption-operations.md`

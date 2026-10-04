# Context Doc: Environment Variables

_Last verified: 2026-10-03 (no CIMD var, CIMD is unconditional, see `connections-client-identity.md`)_

## Status
Live. Covers every var `config/runtime.exs` reads (`Engram.EnvVarDocsTest` fails the build when one lacks a row), plus vars read by helpers, `rel/env.sh.eex` and `entrypoint.sh`. Compile-time defaults come from `config/config.exs`, `config/dev.exs`, `config/test.exs`. Grep `runtime.exs` for the var name; line numbers drift.

## How runtime.exs is shaped (read this first)

- **`APP_SECRETS_JSON`**: prod ships ALL app secrets as one SSM SecureString blob (one KMS decrypt). `Engram.Secrets.unpack/2` expands it into the process env *before* every `System.get_env` below, so the individual var names still resolve. Self-host/dev leave it unset (no-op). Malformed JSON fails boot loudly.
- **Auth shape switch:** `AUTH_PROVIDER` (default `local`) selects self-host (built-in email/password) vs SaaS (`clerk`). Many vars below are required *only* when `clerk`.
- **Billing gate:** `billing_enabled` is derived, `auth_provider == :clerk and PADDLE_API_KEY != nil`. Self-host (or SaaS without a Paddle key) short-circuits the onboarding wizard.
- **Test guard:** blocks gated on `config_env() != :test` (storage, embedder, email, Paddle, key provider) so a developer's exported shell vars can't flip `mix test` onto real adapters.

---

## Core / Endpoint

| Variable | Default | Purpose |
|----------|---------|---------|
| `APP_SECRETS_JSON` | unset | Prod-only bundled-secrets blob, unpacked into env at boot. |
| `PHX_SERVER` | unset | Start the Phoenix server in a release (`bin/engram start`). |
| `PORT` | `4000` | HTTP listen port. |
| `PHX_HOST` | unset (`localhost` for URLs in dev) | Canonical host(s) for URL gen + CORS/WS origin. **Comma-separated; first entry is canonical**. When unset, CORS allows `*` and WS allows all (fine for self-host; a SaaS deploy fails closed if `PHX_HOST` is missing). |
| `PHX_SCHEME` | `https` prod / `http` dev | URL scheme. |
| `PHX_PORT` | `443` prod / `80` dev | URL port for generated links. |
| `DATABASE_URL` |, (required in prod) | `ecto://USER:PASS@HOST/DATABASE`. |
| `POOL_SIZE` | `10` | Ecto pool size. |
| `MAINTENANCE_DATABASE_URL` | unset | Credential for `Engram.Repo.Maintenance`, the pool for work that legitimately spans tenants (orphan reaping, expiry sweeps, credential lookups that *discover* a user_id). **Unset is correct for self-host** — one box, one tenant, connecting as its own database owner; `Engram.Repo.maintenance/0` then resolves to `Engram.Repo` and callers read identically. Unset on a deploy where RLS *is* enforced means those sweeps are filtered to zero rows and report success, which `Engram.Repo.TenancyGuard` logs at boot. On SaaS it should connect as `engram_maintenance` (see `ENGRAM_MAINTENANCE_DB_PASSWORD`), not the migrator. |
| `ENGRAM_MAINTENANCE_DB_PASSWORD` | unset | Applied at boot by `Engram.Release.prepare_database/0` as `ALTER ROLE engram_maintenance PASSWORD` (a SCRAM verifier, never the plaintext), exactly like `ENGRAM_APP_DB_PASSWORD`. Unset or empty is a no-op. The role has no bypass attributes; its cross-tenant reach is the `maintenance_all` policy on each tenant table. Set only where `MAINTENANCE_DATABASE_URL` connects as `engram_maintenance`. |
| `ENGRAM_APP_DB_PASSWORD` | unset | Applied at boot by `Engram.Release.prepare_database/0` as `ALTER ROLE engram_app PASSWORD`. Set where `DATABASE_URL` connects as `engram_app` (SaaS: the RLS-enforced app pool). Unset or empty is a no-op. Read in `lib/engram/release.ex`. |
| `MIGRATOR_DATABASE_URL` | falls back to `DATABASE_URL` | Credential for migrations and `prepare_database/0` (role creation, GRANTs, DDL), which `engram_app` cannot run. Read in `entrypoint.sh`, scoped per command. SaaS points it at the RDS master. |
| `MAINTENANCE_POOL_SIZE` | `2` | Pool size for the above, per node. Ignored unless `MAINTENANCE_DATABASE_URL` is set. Deliberately tiny: it serves a few cron jobs and never a request, and connections are the scarce resource on RDS (see `../engram-workspace/docs/context/prod-db-connection-budget.md`). |
| `ECTO_IPV6` | unset | `true`/`1` → connect to Postgres over IPv6. |
| `DATABASE_SSL` | off | `true` enables TLS to Postgres (required by AWS RDS) (via `RuntimeConfig.database_ssl/2`). |
| `DATABASE_SSL_MODE` | `verify_none` | `verify-full` → `verify_peer` w/ OS trust store + SNI + hostname check. |
| `SECRET_KEY_BASE` |, (required in prod) | Phoenix cookie/secret signing. |
| `JWT_SECRET` |, (required in prod) | Joken default signer for internal JWTs. |
| `DNS_CLUSTER_QUERY` | unset | `dns_cluster` DNS query for BEAM node discovery. When set, the rate limiter auto-selects the distributed ETS + Phoenix.PubSub backend; unset → plain ETS. |
| `ENGRAM_NODE_ROLE` | unset (= runs every queue) | `web` \| `worker`, case- and whitespace-insensitive; any other value **raises at boot**. `web` supervises NO Oban queues on this node — it still enqueues, a worker executes. Opt-out on purpose: unset keeps the full queue list, so self-host and single-node deploys need no configuration. The closed set matters because the opt-out direction makes a typo silent otherwise — `wbe` would mean "run every queue" on a node meant to run none. A `web` node without `DNS_CLUSTER_QUERY` warns at boot (nothing would drain the queues, and `CheckpointNote`'s live-room guard is a `:global` lookup that needs the cluster). |
| `ECS_ENABLE_CLUSTER` | unset | Clustering gate in `rel/env.sh.eex`: when set, the release runs with `RELEASE_DISTRIBUTION=name` and `RELEASE_NODE=engram@<task IPv4>` so `DNS_CLUSTER_QUERY` can connect nodes. Unset (self-host, local) keeps the default short names, no clustering. The Dockerfile fails the build if `env.sh` lacks this gate (#710). |

> `RELEASE_COOKIE` is consumed by the Elixir release runtime (`rel/`/`mix release`), not read in `runtime.exs`.

| Variable | Default | Purpose |
|----------|---------|---------|
| `BEAM_BUSY_WAIT` | unset (BEAM default) | `none` exports `+sbwt none +sbwtdcpu none +sbwtdio none`. A scheduler with no work spins before sleeping, betting new work arrives sooner than a sleep/wake round-trip costs — correct on dedicated hardware, **inverted under a CFS quota**, where spinning consumes the same budget as real work and you can be throttled by threads doing nothing. Set `none` on a CPU-capped task; leave unset on bare metal / self-host, where busy-waiting genuinely lowers latency. Applies independently of `BEAM_SCHEDULERS` (it still takes effect when the quota is unreadable). Anything other than `none`/`default` is ignored with a warning. Read in `rel/env.sh.eex`, so `EnvVarDocsTest` does not enforce this row. Covered by `test/scripts/env_sh_scheduler_clamp_test.sh`. |
| `BEAM_SCHEDULERS` | unset (auto-detect) | Scheduler pool size — exports `+S N:N +SDcpu N:N`. Read in `rel/env.sh.eex`, **not** `runtime.exs`, so `EnvVarDocsTest` does not enforce this row. **Set it to the task's vCPU count on Fargate**, where CPU is enforced on the task's microVM and the container cgroup reports no quota, so auto-detection cannot work — prod ran 2 normal + 2 dirty-CPU schedulers on a 0.5-vCPU task because of this. Elsewhere (self-host, Docker, local) leave it unset; the cgroup quota is readable and auto-detection is correct. Non-numeric or `0` is ignored with a warning and falls back to detection. Covered by `test/scripts/env_sh_scheduler_clamp_test.sh`. |

## Frontend / Hosts / CORS

| Variable | Default | Purpose |
|----------|---------|---------|
| `ENGRAM_SAAS_FRONTEND_ORIGINS` | unset | Extra CORS/WS origins (comma-sep) for the Cloudflare Pages SPA + preview deploys. |
| `ENGRAM_HOST_REWRITE_ENABLED` | unset (`false`) | `true` enables `HostRewrite` plug for the dedicated `api.`/`mcp.engram.page` hosts. Self-host leaves unset → strict no-op. The two hosts are hardcoded in runtime.exs (prod only ever set them to their defaults). |
| `ENGRAM_SAAS_ONLY` | unset | `true` → `reject_unknown_hosts` in HostRewrite. |
| `ENGRAM_ALLOWED_EXTRA_HOSTS` | unset | Comma-sep extra allowed hosts. |
| `ENGRAM_FRONTEND_URL` | unset | Absolute SPA base URL for cross-origin OAuth `/authorize` 302 (post-eject). |
| `OPENAI_APPS_CHALLENGE` | unset | ChatGPT plugin-directory domain-verification token, served as plain text at `/.well-known/openai-apps-challenge` (`WellKnownController`). Public by design. Unset → 404 (self-host). |
| `ENGRAM_UPGRADE_URL` | `https://app.engram.page/#settings/billing` | Upgrade URL surfaced in 402 limit-exceeded responses. |
| `TRUST_CF_CONNECTING_IP` | `false` | Prod-only: trust `CF-Connecting-IP` for rate-limit client IP. Safe only under Cloudflare AOP `verify`. |

## Storage / Attachments

> **`STORAGE_BACKEND` code default is `s3`** (`System.get_env("STORAGE_BACKEND", "s3")`). `s3` is the SaaS/prod (AWS S3) and standard self-host (MinIO) path. `database` (#297) is a self-host-only convenience that stores opaque ciphertext in the generic `storage_objects` table (NOT the removed `attachments.content` column). Unknown values raise at boot.

| Variable | Default | Purpose |
|----------|---------|---------|
| `STORAGE_BACKEND` | `s3` | `s3` or `database`. |
| `STORAGE_BUCKET` | `engram-attachments` | S3 bucket. |
| `STORAGE_ACCESS_KEY_ID` | unset | Static S3 key (MinIO/non-AWS). Leave unset on ECS to use the task role. |
| `STORAGE_SECRET_ACCESS_KEY` |, | Paired secret (required if access key set). |
| `STORAGE_REGION` | `auto` when `STORAGE_ACCESS_KEY_ID` is set; otherwise `AWS_REGION`, then `us-east-1` | S3 region. |
| `STORAGE_HOST` | unset | Endpoint host override for MinIO / non-AWS S3. |
| `STORAGE_SCHEME` | `https://` | Used only when `STORAGE_HOST` set. |
| `STORAGE_PORT` | `443` | Used only when `STORAGE_HOST` set. |

## Embedding (Voyage / Ollama)

> Embedder default is `voyage` (`EMBED_BACKEND` defaults to `voyage`). `ollama` selects the self-host adapter.

| Variable | Default | Purpose |
|----------|---------|---------|
| `EMBED_BACKEND` | `voyage` | `voyage` or `ollama`. |
| `VOYAGE_API_KEY` | unset | Voyage AI key (used when backend = voyage). |
| `EMBED_MODEL` | (compile-time) | Override symmetric embed model. |
| `EMBED_DIMS` | (compile-time) | Override vector dimensions. Sent to Voyage as `output_dimension` ONLY when set, because the older models (`voyage-2`, `voyage-3-lite`, `voyage-law-2`, ...) reject that field and would 400 every embed. Set it only on a model that accepts it: the `voyage-4` family, `voyage-3-large`, `voyage-3.5`, `voyage-code-3`. |
| `DOC_EMBED_MODEL` | falls back to `EMBED_MODEL` | Asymmetric: doc-indexing model. |
| `QUERY_EMBED_MODEL` | falls back to `EMBED_MODEL` | Asymmetric: query model. |
| `EMBED_429_SNOOZE_SECONDS` | `60` | Voyage-429 snooze (worker reschedules without burning an attempt). |
| `EMBED_SETTLE_SECONDS` | `30` | Settle debounce — a note must sit unedited this long before it embeds, collapsing a burst of saves into one Voyage call. Higher = cheaper, staler index. |
| `EMBED_SETTLE_MAX_WAIT_SECONDS` | `300` | Starvation ceiling — a continuously-edited note embeds at most this long after its first pending edit. Keep **>** `EMBED_SETTLE_SECONDS`. |
| `BACKGROUND_JOB_PRIORITY` | `low` | BEAM scheduler priority for embed/indexing job processes. `low` means a job runs only when no `normal` process — every Phoenix channel serving a live sync — is runnable, so a bulk upload cannot starve the user's own sync. Kill-switch: set `normal` to revert without a deploy if indexing ever starves under sustained load. Only `normal` and `low` are accepted; anything else raises at boot. |
| `EMBED_POISON_COOLDOWN_SECONDS` | `21600` (6h) | Cooldown parked on a note that exhausts its embed attempts, before `ReconcileEmbeddings` retries. Caps re-billing on permanently-failing notes. |
| `EMBED_TRANSIENT_COOLDOWN_SECONDS` | `300` | Shorter cooldown for *transient* failures (upstream unreachable / 5xx) so a provider blip doesn't strand notes for the full poison window. Effective recovery is bounded below by the ~15min reconcile sweep. |
| `EMBED_RECONCILE_BACKOFF_SECONDS` | `1800` (30m) | Preemptive cooldown stamped on every note `ReconcileEmbeddings` enqueues (#897) — makes backoff crash-independent (an OOM that skips the graceful poison stamp still can't re-enqueue immediately). **MUST exceed the 15-min reconcile cron interval.** |
| `VOYAGE_RPM` | unset (no throttle) | Client-side cap, synthetic 429 before real call. |
| `VOYAGE_QUERY_RPM` | falls back to `VOYAGE_RPM` | Separate bucket for synchronous search. |
| `OLLAMA_URL` | (adapter default `http://localhost:11434`) | Ollama server (self-host). |

## Vector DB (Qdrant)

> **`QDRANT_COLLECTION`, nuance.** `runtime.exs` only sets the config when the env var is present. The *fallback if unset* differs by source: dev/test config pin `engram_notes` (`config/dev.exs`, `config/test.exs`), but the module-level `Application.get_env(:engram, :qdrant_collection, "obsidian_notes")` fallback is **`obsidian_notes`** (`lib/engram/indexing.ex`, `lib/engram/search.ex`, `@default_collection` in `lib/engram/vector/qdrant.ex`). In prod the collection comes from the `QDRANT_COLLECTION` env var; the live prod collection is **`engram_notes`** (set explicitly). Net: never rely on the implicit fallback in prod, set `QDRANT_COLLECTION` explicitly.

| Variable | Default | Purpose |
|----------|---------|---------|
| `QDRANT_URL` | (compile-time) | Qdrant base URL. |
| `QDRANT_COLLECTION` | env-driven; fallback `obsidian_notes` (module) / `engram_notes` (dev+test+prod) | Collection name. See nuance above. |
| `QDRANT_API_KEY` | unset | Qdrant Cloud key. |
| `QDRANT_BINARY_QUANTIZATION` | on | Set `false` to disable BQ on non-AVX2 hardware. |

## Search / Reranker

| Variable | Default | Purpose |
|----------|---------|---------|
| `RERANKER_BACKEND` | `none` | `jina` or `none`. |
| `JINA_URL` |, (required when `RERANKER_BACKEND=jina`) | Reranker URL. |

## Auth (local / Clerk)

| Variable | Default | Purpose |
|----------|---------|---------|
| `AUTH_PROVIDER` | `local` | `local` (built-in email/password) or `clerk` (SaaS JWKS). |
| `ENGRAM_DEFAULT_REGISTRATION_MODE` | `invite_only` | Self-host registration default: `closed` / `invite_only` / `open`. |
| `CLERK_JWKS_URL` |, (required if clerk) | Clerk JWKS endpoint. |
| `CLERK_ISSUER` |, (required if clerk) | Clerk issuer. |
| `CLERK_PUBLISHABLE_KEY` |, (required if clerk) | Clerk publishable key. |
| `CLERK_SECRET_KEY` | unset | Backend API key (`sk_*`), revoke duplicate signups (pricing v2 §A). |
| `CLERK_WEBHOOK_SECRET` | unset | Verifies inbound svix signatures (`whsec_*`). |
| `CLERK_AUTHORIZED_PARTIES` | unset (passthrough) | Comma-sep `azp` allowlist. |

## Encryption / Key Provider

| Variable | Default | Purpose |
|----------|---------|---------|
| `KEY_PROVIDER` | `local` | `local` or `aws_kms`. |
| `ENCRYPTION_MASTER_KEY` | unset | Master key for wrapping per-user DEKs (local provider). |
| `ENCRYPTION_MASTER_KEY_PREVIOUS` | unset | Old master key during rotation. |
| `ENCRYPTION_MASTER_KEY_VERSION` | `1` | Master key version. |
| `DEK_CACHE_TTL_MS` | `3600000` (1h) | DEK cache TTL. |
| `BOOT_CANARY_ENABLED` | on | `false` disables the boot canary during master-key rotation window. See `encryption-operations.md`. |
| `AWS_KMS_KEY_ID` |, (required if `KEY_PROVIDER=aws_kms`) | KMS CMK id. |
| `AWS_REGION` |, (required for KMS; also S3 region fallback) | AWS region. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | unset | Static KMS creds; unset on ECS → task role. |

## Email (Resend)

> Default provider is NoOp; Resend activates when `RESEND_API_KEY` is set (non-test only).

| Variable | Default | Purpose |
|----------|---------|---------|
| `RESEND_API_KEY` | unset | Activates `Engram.Email.Resend`. |
| `EMAIL_FROM` | unset | From-address override. |
| `RESEND_WEBHOOK_SECRET` | unset | `whsec_*` for `POST /webhooks/resend` (bounce/complaint). Unset → endpoint rejects all events. |

## Billing (Paddle — MoR)

Paddle is the Merchant-of-Record. Server keys gate API calls; the client token feeds the Paddle.js overlay; price IDs are **split monthly/annual per tier** (not a single `PADDLE_<TIER>_PRICE_ID`). See `docs/context/paddle-integration.md`. All Paddle config is non-test-only.

| Variable | Default | Purpose |
|----------|---------|---------|
| `PADDLE_ENV` | `sandbox` | `sandbox` or `production`. |
| `PADDLE_API_KEY` | unset | Server-side key; also gates `billing_enabled`. |
| `PADDLE_NOTIFICATION_SECRET` | unset | Webhook signing secret. |
| `PADDLE_CLIENT_TOKEN` | unset | Public token for the overlay. |
| `PADDLE_STARTER_MONTHLY_PRICE_ID` | unset | Starter monthly `pri_*`. |
| `PADDLE_STARTER_ANNUAL_PRICE_ID` | unset | Starter annual `pri_*`. |
| `PADDLE_PRO_MONTHLY_PRICE_ID` | unset | Pro monthly `pri_*`. |
| `PADDLE_PRO_ANNUAL_PRICE_ID` | unset | Pro annual `pri_*`. |

## Limits & Plan Enforcement

> Per-tier numeric limits are NOT individual env vars anymore. They are defined by `Engram.Billing.LimitKeys` and overridden via generated `ENGRAM_<TIER>_<KEY>` env vars parsed at boot. Bad values fail boot. Old knobs `REGISTRATION_ENABLED`, `MAX_ATTACHMENT_SIZE`, `MAX_STORAGE_PER_USER`, `MAX_NOTE_SIZE`, `RATE_LIMIT_RPM` are **gone**, migrated to LimitKeys.

| Variable | Default | Purpose |
|----------|---------|---------|
| `ENGRAM_LIMITS_ENFORCED` | derived (`clerk` + Paddle key) | `true`/`false` override of plan-limit enforcement. |
| `ENGRAM_<TIER>_<KEY>` | unset | Per-tier limit overrides (e.g. `ENGRAM_FREE_MAX_NOTES`); names come from `LimitKeys.env_var_names/0`. |
| `ATTACHMENT_MIME_BYPASS` | off (gate ON) | `true` disables the MIME/extension whitelist. |
| `ATTACHMENT_MIME_ALLOWLIST_EXTRA` | unset | Comma-sep extra allowed MIMEs without disabling the gate. |
| `RATE_LIMIT_AUTH_OVERRIDE` | ignored unless `CI=true` | Auth-limiter override for CI/E2E only. |
| `PRE_AUTH_RATE_LIMIT_OVERRIDE` | ignored unless `CI=true` | Pre-auth (vault-pipeline) limiter override for CI/E2E only. |
| `CRDT_MSG_RATE_LIMIT_OVERRIDE` | ignored unless `CI=true` | `CrdtChannel` per-message budget override for CI/E2E only. |
| `CRDT_HS_RATE_LIMIT_OVERRIDE` | ignored unless `CI=true` | `CrdtChannel` handshake budget override for CI/E2E only. |
| `CI` | unset | `true` unlocks the four rate-limit overrides above. |

> The canonical list of overridable limiters is
> `Engram.RuntimeConfig.rate_limit_overrides/0` — runtime.exs walks it, and a
> unit test pins the env var names. Add a limiter override there, not by
> copying a block into runtime.exs.

## Sync / CRDT fan-out

| Variable | Default | Purpose |
|----------|---------|---------|
| `FANOUT_PACING_ENABLED` | unset (pacing **on**) | `false` falls back to unpaced inline broadcast per note, the instant-rollback lever for the vault-channel fan-out pacer (#1002). Read into app config at boot; `Engram.Notes.FanoutPacer` reads that config per call, so flipping it without a new task needs a remote-console `Application.put_env`. The cold-queue depth gauge exists (`..._fanout_pacer_queue_depth`, `Engram.PromEx.Reliability`); check it before using this lever. |

## Observability (Sentry / PostHog / Pyroscope / Metrics)

Each block is opt-in: unset → no-op (dev/test/self-host emit nothing).

| Variable | Default | Purpose |
|----------|---------|---------|
| `METRICS_AUTH_TOKEN` | unset | Bearer guarding the PromEx `/metrics` scrape. Unset → `MetricsAuth` plug fails closed (endpoint disabled). |
| `SENTRY_DSN` | unset | Sentry error tracking. |
| `RELEASE_SHA` | unset | Sentry release tag, must match `getsentry/action-release`. |
| `POSTHOG_API_KEY` | unset | Server-side PostHog capture. |
| `POSTHOG_HOST` | `https://us.i.posthog.com` | PostHog ingest host. |
| `POSTHOG_ERASURE_API_KEY` | unset | Separate, write-scoped PostHog key for `Engram.Observability.PostHog.delete_person/1`, called from account hard-delete (GDPR Art. 17). Deliberately not `POSTHOG_API_KEY`, that one stays capture-only/read-only. |
| `POSTHOG_PROJECT_ID` | unset | PostHog project id for the erasure API (`/api/projects/:id/persons/`). Erasure no-ops when either this or `POSTHOG_ERASURE_API_KEY` is unset, self-host/dev. |
| `GRAFANA_PYROSCOPE_URL` | unset | Enables continuous CPU profiling. |
| `GRAFANA_PYROSCOPE_USERNAME` |, (required if Pyroscope URL set) | Pyroscope username. |
| `GRAFANA_AGENT_TOKEN` |, (required if Pyroscope URL set) | Pyroscope push token. |
| `PYROSCOPE_APP_NAME` | `engram-saas-prod` | Pyroscope app label. |
| `HOSTNAME` / `ECS_TASK_ID` | `unknown` | Pyroscope instance label. |
| `PYROSCOPE_SAMPLE_INTERVAL_MS` | `10` | Profiler sample period. Lower = finer profiles, more CPU, this knob is why prod CPU jumped, see `../engram-workspace/docs/context/pyroscope-cpu-profiler-prod-regression.md`. Prod sets `2000`. |
| `PYROSCOPE_PUSH_INTERVAL_MS` | `10000` | How often collected profiles are pushed. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | **Master switch for tracing** — unset → OTel is a no-op. Prod points it at the Alloy sidecar on loopback; Alloy forwards to Tempo. |
| `ENGRAM_OTEL_SAMPLE_RATIO` | `1.0` | Head-sampling ratio, tunable without a code deploy. Applies *after* `Engram.Observability.TraceSampler` drops health-check/scrape traffic (~96% of span volume) at the root — under `:parent_based` a root `:drop` cascades, so probe traces never build children. |
| `TELEMETRY_HMAC_KEY_USER_ID` | unset (per-boot random + warning) | HMAC key for hashing user ids in metric labels/logs — **distinct from any encryption key**. SaaS prod + staging set it via SOPS so `user_id_hmac` correlates across restarts; unset still never leaks plaintext ids, it just breaks correlation across reboots. |
| `HMAC_KEY_ANALYTICS_ID` | unset (per-boot random) | Keys `Engram.Observability.PostHog.analytics_id/1` — a pseudonymous id derived from a user's email for PostHog. Separate secret from `TELEMETRY_HMAC_KEY_USER_ID` on purpose (domain separation). SaaS prod sets it via SOPS so the id is stable across restarts; self-host/dev leave it unset since analytics is off anyway (no `POSTHOG_API_KEY`). Non-rotating by design — rotating it re-identifies every person in PostHog. |

## Notes on removed / migrated vars

- `REGISTRATION_ENABLED` → replaced by `ENGRAM_DEFAULT_REGISTRATION_MODE` + `Engram.Instance.registration_mode/0`.
- `MAX_ATTACHMENT_SIZE`, `MAX_STORAGE_PER_USER`, `MAX_NOTE_SIZE`, `RATE_LIMIT_RPM` → moved into `Engram.Billing.LimitKeys` (per-tier; override via `ENGRAM_<TIER>_<KEY>`).
- Legal version/hash env vars → dropped; legal docs now live in the `terms_versions` table seeded from `priv/legal/legal-manifest.json`.

## References
- Runtime config (source of truth): `config/runtime.exs`
- Compile-time defaults: `config/config.exs`, `config/dev.exs`, `config/test.exs`
- Module-level Qdrant collection fallback: `lib/engram/indexing.ex`, `lib/engram/search.ex`, `lib/engram/vector/qdrant.ex`
- Limit keys: `Engram.Billing.LimitKeys`
- Paddle: `docs/context/paddle-integration.md`
- Encryption: `docs/context/encryption-operations.md`

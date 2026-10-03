# Context Doc: Elixir Architecture Decisions

_Last verified: 2026-10-03_

The why behind the backend's shape, and what was rejected. Versions live in
`mix.exs`; prod env lives in engram-infra `main/envs/prod/*.tf`.

## Current decisions

| Area | Decision | Why |
|------|----------|-----|
| Language | Elixir/Phoenix | BEAM for many concurrent connections, OTP supervision, Channels for bidirectional sync. |
| Real-time | Phoenix Channels + `Phoenix.PubSub` (pg) | Bidirectional, cluster-native fan-out, no broker. |
| Clustering | `DNSCluster` on `DNS_CLUSTER_QUERY` (AWS Cloud Map in prod) | Live since Engram#717. Unset (self-host, single node) means no clustering. |
| Multi-tenancy | Postgres RLS, `SET LOCAL` tenant per transaction | DB-enforced, fail-closed. A `Repo.prepare_query` tripwire raises on unscoped tenant queries. See `database-schema-rls.md`. |
| DB roles | `engram_owner` (migrations), `engram_app` (runtime, under RLS), `engram_maintenance` (maintenance pool) | See `maintenance-db-role.md`. |
| IDs | `uuid` PKs from `uuidv7()` | Time-ordered; notes are id-addressable. Requires Postgres 18. |
| Caching | Node-local ETS, evictions over `Engram.Cluster.CacheSync` | No Redis. Caches that must be coherent also LISTEN on Postgres NOTIFY. See `perf-caching-invalidation.md`. |
| Rate limiting | Hammer: ETS, distributed ETS + PubSub when clustered; Postgres token bucket (`usage_buckets`) for the durable daily search cap | No Redis. See `rate-limiter-architecture.md`. |
| Job queue | Oban on the same Postgres | Durable jobs, no new infra. No Oban Pro. See `async-indexing-pipeline.md`. |
| Auth | Clerk JWTs via Joken + `joken_jwks`; API keys as SHA256 hashes, looked up directly by indexed `key_hash` | No key cache. |
| Embeddings | Voyage, asymmetric: `voyage-4-large` (1024d) for documents, `voyage-4-lite` for queries | Shared Voyage 4 space. Self-host uses Ollama (`lib/engram/embedders/ollama.ex`). |
| Vector DB | Qdrant, thin Req HTTP wrapper | No official Elixir SDK; the REST API is small. |
| Search | Hybrid dense + BM25 sparse with server-side RRF; reranker pluggable (`RERANKER_BACKEND=jina|none`, default `none`, unset in prod) | See `chunk-boundary-stability.md`. |
| Markdown | Line/regex section splitter (`lib/engram/parsers/markdown.ex`) for chunking; `mdex_native` (comrak) for MCP section boundaries | Earmark is still in `mix.exs` but no code in `lib/` uses it. |
| MCP server | Hand-rolled (`lib/engram/mcp/`) | No external MCP dependency. |
| Storage | ExAws S3 (+ KMS) | AWS S3 in prod, MinIO for self-host/staging. |
| Email | Resend, gated on `RESEND_API_KEY` | |
| Billing | Paddle (Merchant of Record) | See `paddle-integration.md`. |
| Observability | PromEx + Sentry | |
| App structure | Single OTP app, `one_for_one` | No umbrella. A web/worker split is a runtime role (`ENGRAM_NODE_ROLE`), not a separate app. |
| Prod | AWS ECS Fargate + RDS + S3, GitOps deploy | See `deploy-prod.md`. FastRaid is staging. |

## Rejected alternatives

| Rejected | Why |
|----------|-----|
| Kafka / RabbitMQ | Oban on the existing Postgres covers it with no new failure mode. |
| Redis (PubSub, cache, Hammer backend) | BEAM-native PubSub, ETS and Postgres cover every use. Redis was removed entirely. |
| Hermes MCP | Not adopted; the hand-rolled JSON-RPC server is what shipped. |
| BIGSERIAL internal ids with path as identifier | Reversed for `uuidv7` PKs. |
| voyage-4-nano for self-host embeddings | Still needs a Voyage API key, which contradicts "free, on your own infra". Ollama instead. |
| Umbrella app | Not needed at this scale. |
| Fly.io (compute, Postgres, Tigris) | Prod went to AWS. There is no Fly app; never run `fly` commands. |
| Exact tokenizer for chunking | ~4 chars/token is enough; Voyage tokenizes. |

## References
- `mix.exs` (dependencies and versions)
- `docs/context/deploy-prod.md`, `docs/context/disaster-recovery.md`
- Pricing: `../engram-workspace/docs/context/pricing-tiers-v2-decisions.md`

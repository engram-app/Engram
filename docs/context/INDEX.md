# Context doc index

Trigger → doc. Not auto-loaded: a prompt hook injects matching lines, and agents grep this file before non-trivial work in an area. Add every new doc's trigger line HERE, never to CLAUDE.md/AGENTS.md.


Grouped index into `docs/context/`. Each entry is a trigger → doc; read the doc itself for full detail.

**Architecture & Decisions**
- Changing chunking, tokenizing or what the keyword leg encodes (version stamps, the reconcile sweep, why "run X per vault after deploy" is a defect) → `docs/context/index-version-self-heal.md`
- Adding a backfill that must reach existing rows (`Engram.DataMigration`, completion ledger, `any_row?`, `:done` semantics, why not an operator command) → `docs/context/data-migrations-ledger.md`
- Elixir decision audit, library deps, infra checklist (partially superseded — read inline corrections) → `docs/context/elixir-architecture-decisions.md`
- RLS policy set (12 tenant tables, `api_keys_discovery`, `maintenance_all`), DB roles, `with_tenant`/`cross_tenant`/`maintenance()`/`skip_tenant_check` semantics → `docs/context/database-schema-rls.md`
- Adding a tenant table (needs its own `maintenance_all`), the `MAINTENANCE_DATABASE_URL` credential, why it is not BYPASSRLS → `docs/context/maintenance-db-role.md`
- `api_keys_discovery` policy (why `api_keys` stays in the tenant set; never roll back 20260918120000) → `docs/context/rls-cutover-breaks-api-key-auth.md`
- Retiring a column in stages: never switch reads AND stop writes in one release → `docs/context/migrate-data-rollback-trap.md`
- Touching `RedactFilter` or logging near a vault path (drop the dep message, never scrub it; a raising primary filter disables ALL redaction node-wide) → `docs/context/log-redaction-boundaries.md`
- Writing a `use` macro that injects GenServer callbacks (`__before_compile__` defs lose to `defoverridable` defaults, silently) → `docs/context/before-compile-defoverridable-trap.md`
- Reading `TenancyGuard`'s boot line / re-verifying RLS enforcement on a deploy, or touching the probe (`:savepoint` outermost, sandbox can't test it, `reltuples`, `$1::regclass`) → `docs/context/rls-tenancy-probe-boot-log.md`
- Widening a column type without rewriting the table (`varchar[]` → `text[]` DOES rewrite; how to measure with relfilenode; when `# squawk-ignore-file` is justified) → `docs/context/migration-column-type-rewrites.md`
- All env vars by category → `docs/context/environment-variables.md`
- Rate limiter + `ai_searches_per_day` budget: BEAM-only (Hammer ETS + PubSub), zero Redis; why NOT Mnesia → `docs/context/rate-limiter-architecture.md`
- Gating API keys or MCP by plan, re-adding a connection cap, or "is the API Pro-only?" (no: keys work everywhere on every tier; one cost meter + rate limits; removing a limit key needs no migration) → `docs/context/api-access-and-mcp-limits.md`
- Adding a plan-limit / abuse gate as a plug, or a Free cap is not firing for a user clearly over it (a `request_path` guard cannot see MCP — every tool is one route, named in the JSON-RPC body) → `docs/context/mcp-bypasses-path-shaped-plugs.md`
- Proving a limit is actually WIRED (delete the gate line and re-run; a green suite means unproven) → `docs/context/mcp-bypasses-path-shaped-plugs.md`
- Reading a plan limit as a NUMBER, or a `-1` operator override made a user MORE restricted (`effective_limit/2` returns four spellings of "no limit" — use `Billing.cap/2` / `granted?/2`) → `docs/context/limit-sentinel-decoding.md`
- Adding a top-level route / Plug.Static mount / Phoenix scope / Cloudflare rule, and wondering if it can collide with a vault name (it cannot — vault URLs are `/v/:slug`; the old `@reserved_slugs` list is deleted) → `docs/context/vault-url-prefix-and-collision-surface.md`
- Making a route edge-cacheable, or adding a host/path to the Cloudflare Cache Rule (headers that vary by request poison a shared entry; `Vary` is ignored) → `docs/context/edge-cache-request-varying-headers.md`

**Sync & CRDT**
- Server-side sync protocol: seq change-log, `crdt_catchup_since` page builder, manifest, realtime channel (start here for sync work) → `docs/context/sync-protocol.md`
- Phoenix Channel events, conflict flow, plugin integration → `docs/context/channel-event-contract.md`
- Parallelising channel work (`Task.async_stream`) without starving the DB pool / killing the channel → `docs/context/channel-parallelism-db-pool.md`
- Unit-suite flake `could not checkout the connection owned by #PID` (sandbox shares the owner's connection — `pool_size` is NOT the lever) → `docs/context/channel-parallelism-db-pool.md`
- FanoutPacer hot/cold rules, why a note won't warm to HOT, testing it without flaking → `docs/context/fanout-pacer-hot-cold-and-testing.md`
- A web-app rename reverts to its old path, or you are adding a write path that moves a note's row → `docs/context/crdt-create-is-a-rename.md`
- Who owns note→path identity (`filemeta_v0` map is authoritative; claim before the row moves, outside any transaction) → `docs/context/crdt-identity-authority.md`
- The per-vault index room (`filemeta_v0`): wire, projection onto `notes.path_*`, why it drains with no off switch → `docs/context/crdt-index-room.md`
- A CRDT room won't go away, resident rooms climb, or tuning `CRDT_IDLE_EXIT_MS`/`CRDT_MAX_RESIDENT_ROOMS` → `docs/context/crdt-room-lifetime-and-drain.md`
- Background worker processed stale note content (facade vs `authoritative_content`) → `docs/context/worker-reads-stale-content-facade.md`
- Worker CPU pegged and "nothing alerted", or assuming a `severity=page` alert woke someone (CloudWatch twin did fire; `page` routes only to Discord) → `docs/context/worker-oom-regex-backtrack-2026-10-03.md`
- Measuring CRDT doc bloat, or reading the engram-crdt dashboard (the checkpoint flatten was removed in 0.60.1 because it doubles bodies; never reintroduce a server reset) → `docs/context/crdt-bloat-measurement-traps.md`
- The CRDT bloat alert fires on a small note, or reading `notes.version` as an edit count (it counts debounced checkpoints, ~2 per typing burst; 64 KB floor + save-rate gauges, #2175) → `docs/context/crdt-bloat-measurement-traps.md`
- Note content doubled or interleaved, or the server holds a note TWICE (one-encoder invariant, frontmatter re-seed, flatten boundary #958) → `docs/context/crdt-lineage-doubling.md`
- Note version history, the outbox write path, adding a content-write path or an MCP write tool → `docs/context/note-revisions-history.md`
- Every `crdt_create` returns `create_failed` on a NEW vault, or a create leg drops a re-minted note id → `docs/context/crdt-create-cross-vault-id-reuse.md`
- `Repo.with_tenant/2` funs return bare values (or use `with_tenant!/2`), never `{:ok, _}` → `docs/context/with-tenant-return-wrapping.md`
- `y-indexeddb` `whenSynced` never resolves after `destroy()` → `docs/context/y-indexeddb-whensynced-destroy-hang.md`

**Indexing & Search**
- Oban indexing pipeline — dedup/debounce, retry, re-indexing → `docs/context/async-indexing-pipeline.md`
- Adding an Oban worker or cron, or code that marks rows for later processing (queue it when due; the queue throttles, crons are backstops; no two crons share a minute) → `docs/context/oban-scheduling-model.md`
- Stranded Qdrant points after a rename → delete race → `docs/context/qdrant-orphan-points-rename-delete-race.md`
- `DELETE /api/me` slow or 410 on retry, adding Qdrant work to a request path, or `test_62 test_member_delete_blocks_future_login` red on every branch at once (shared CI Qdrant stalled; e2e retry policy is `e2e/helpers/http_retry.py`) → `docs/context/account-delete-off-qdrant.md`
- Qdrant payload indexes missing or rejected under strict mode (`ensure_collection/2` reconciles them on every boot) → `docs/context/qdrant-payload-indexes-strict-mode.md`
- A Qdrant scroll/search/filter 400s on every retry (prod strict mode refuses unindexed payload keys; `ReconcileNotePayloads` v5 key `u`, #2138; build filters via `Qdrant.match_filter(:user, ...)`, index a key before any reader uses it) → `docs/context/qdrant-strict-mode-unindexed-filter.md`
- An edit re-embeds far more chunks than it changed, or you are about to change how `split_text/2` packs chunks (boundaries cascade to the end of the heading section; paragraph-granularity looks like a free fix and is not) → `docs/context/chunk-boundary-stability.md`
- Measuring chunk reuse (repeated synthetic paragraphs + `MapSet` gives a wrong answer — match with multiplicity) → `docs/context/chunk-boundary-stability.md`
- Lingua NIF memory — `low_accuracy_mode` dial, the #891 OOM crash-loop → `docs/context/lingua-language-detection-memory.md`

**Billing & Pricing**
- Paddle MoR integration, webhook signature, event lifecycle, `custom_data`, affiliate flow, list pagination (stop on `has_more`, never `next`) → `docs/context/paddle-integration.md`
- `tier` values contract (default `free`, gate on `!active`) → `docs/context/billing-tier-frontend-contract.md`
- Attachment executable blocklist (was the MIME whitelist, Pricing v2 §H) → `docs/context/attachment-mime-whitelist.md`
- Attachments over the 11 MB request ceiling, resumable `/api/attachment-uploads` parts protocol, content format v2, rotation gate on attachment writes → `docs/context/attachment-chunked-upload.md`
- Self-host silently drops attachments, or you are renaming/adding a boolean plan-limit key (`true` must always mean GRANTED) → `docs/context/self-host-capability-polarity.md`
- Changing a request shape an older plugin still sends, or raising the plugin version floor (mark the old path `compat(plugin)`, delete shims at the floor) → `docs/context/plugin-compat-shims.md`

**Auth, OAuth & MCP**
- Gating a Phoenix **channel** on onboarding/billing, or a paywalled account is syncing anyway (`RequireOnboarding` is a Plug and never runs on a socket; `user:` must stay UNGATED) → `docs/context/onboarding-gate-is-http-only.md`
- A test asserting paywall/tier/onboarding behavior passes but shouldn't (`config/runtime.exs` clobbers `billing_enabled` to false for the whole suite) → `docs/context/onboarding-gate-is-http-only.md`
- OAuth 2.1 + DCR on `/api/mcp` — wire flow, endpoints, token model, scopes → `docs/context/mcp-oauth.md`
- Codex MCP connections die and retry a dead refresh token forever, or the OAuth refresh-loop alert fires on one family kill (Codex <= 0.163 race; alert on families killed, not rejections) → `docs/context/mcp-oauth.md`
- OAuth discovery advertises a `:80` port, or an MCP client can't reach the auth server behind edge-terminated TLS → `docs/context/oauth-discovery-urls-behind-edge-tls.md`
- What the MCP conformance suite does and does not prove (green means a lenient client coped; CIMD coverage is one vendor's document; OAuth stage runs on staging only) → `docs/context/mcp-conformance-suite-limits.md`
- CIMD documents are negotiated, DCR registrations are policed, don't share the changeset (the 2026-08-04 outage: every Claude connect died on `invalid_client`) → `docs/context/cimd-vs-dcr-validation-policy.md`
- A user who signed up INSIDE an MCP client's OAuth flow gets valid tokens and then 403 `onboarding_required` on every tool call forever (nothing in the grant path runs or links onboarding; `device_auth_controller.ex:21` is the existing precedent for relaxing it) → `docs/context/mcp-first-signup-onboarding-deadend.md`
- Auditing prod for users who never onboarded (`engram_audit_ro` is RLS-bound — a correlated subquery over `users` returns 0 for every row, silently; prod Loki ships warn+ only, so successful 2xx traffic is invisible) → `docs/context/mcp-first-signup-onboarding-deadend.md`
- Publishing to the official MCP registry (`server.json`, `mcp-publisher`, GitHub namespace auth), a personal `mcp-publisher login github` 403s on the org namespace (publish runs via OIDC on each release tag), or changing the listing title/description → `docs/context/mcp-registry-publishing.md`
- A third-party MCP directory (Smithery, MCPRush) scan or gateway 403s on `mcp.engram.page` (it is `McpOriginGuard` rejecting the gateway's Origin, NOT Cloudflare Bot Fight Mode), or serving the SEP-1649 server card → `docs/context/mcp-directory-listing-and-gateway-origins.md`
- Submitting or updating the ChatGPT plugin directory listing (ZIP from `openai-plugin/`, never "Upload new", domain-challenge route, reviewer login via Clerk `bypass_client_trust`) → `docs/context/openai-plugin-directory-submission.md`
- Changing an MCP tool definition, or the TDQS lint job is red (regenerate `mcp-tools.json`; model-graded scoring is a hosted post-release report, not a CI job) → `docs/context/mcp-tdqs-baseline.md`
- Refresh-token rotation — leeway/overlap window, token-family reuse detection → `docs/context/refresh-token-reuse-detection.md`
- How `/settings/connections` + the onboarding checklist identify an OAuth/MCP client (slug attribution, the three hosting classes, HTTPS trust model) → `docs/context/connections-client-identity.md`

**Frontend / SPA**
- Frontend SPA map — bootstrap chain, runtime router, api/sync/realtime layer, viewer/editor (start here for web-app work) → `docs/context/frontend-architecture.md`
- Form controls and buttons: the one control height (`--spacing-control`), `<Input>` vs raw `<input>`, button role -> variant/size, the `<Button>` className rule → `docs/context/form-controls.md`
- Adding/editing a UI string, adding a language, or a bad translation (translategemma pipeline, diff-only CI bot, model-free gates) → `docs/context/webapp-i18n.md`
- Spot-checking the twelve web-app translations in a browser (language switch and auto-detect, surface checklist, per-locale native-speaker review list, known gaps) → `docs/context/webapp-i18n-spot-check.md`
- Wikilink (`[[...]]`) → note resolution in the SPA viewer → `docs/context/spa-wikilink-resolution.md`
- Footnotes in the CM6 editor: build vs adopt → `docs/context/codemirror-footnote-options.md`
- Matching Obsidian's real Properties panel CSS/geometry → `docs/context/obsidian-properties-parity.md`
- A Radix menu item that opens an inline editor (use `modal={false}`, or the blur-committing input fights the menu) → `docs/context/radix-modal-menu-vs-blur-committing-input.md`
- An e2e locator or screen reader stopped seeing a string after you swapped text for an input/icon → `docs/context/text-to-control-breaks-locators-and-a11y.md`
- Who is using Engram: activity events, the PostHog surfaces, real DAU → `docs/context/product-activity-analytics.md`
- Customer insights: our own event log (`analytics_events`), daily snapshots, the operator role and `/api/operator/insights` reports → `docs/context/customer-insights.md`
- Touching `frontend/src/analytics/`, the `/ph` proxy, or bumping `posthog-js` (SDK-added `$current_url` leaks vault slugs; `sanitize_properties` is deprecated and fails open) → `docs/context/posthog-instrumentation-traps.md`
- Web app 404s every vault-scoped call (folders/attachments/notes), or a client-only fixture id poisoned persisted `activeVaultId` → `docs/context/stale-active-vault-404s.md`
- `window.__ENGRAM_CONFIG__` first-paint state injection pattern → `docs/context/spa-state-injection.md`
- Login boot perf (PR #842) — chunk-size measurement, VLQ-decode under hidden sourcemaps → `docs/context/frontend-login-boot-perf.md`
- Lighthouse CLS fails the release gate on some runs and scores 0.000 on others (empty-opened Y.Doc paints the editor, properties land above it; read LayoutShift rects from the trace before theorizing) → `docs/context/lighthouse-cls-empty-doc-open.md`
- Folder-tree `rebuildTree()` triggers, optimistic move/delete/duplicate → `docs/context/folder-tree-optimistic-rebuild.md`
- The sidebar tree flashes empty every few minutes, or you are writing query options a caller reads via `getQueryData`/`fetchQuery` (no observer → `gcTime` deletes the entry, and `invalidateQueries` won't refetch it) → `docs/context/folder-tree-optimistic-rebuild.md`
- Adding a cache that holds note/folder data, or wondering why a sidebar view has no key of its own (one `['vault-tree']` query, everything else is a `select` view of it) → `docs/context/folder-tree-optimistic-rebuild.md`
- A web-app folder delete reverts ~1s later, or you are touching any folder route (a folder is EITHER a `kind="folder"` marker row OR derived from the paths of the notes/attachments inside it) → `docs/context/derived-vs-marker-folders.md`
- Adding a `?flag=true` query param to a controller (nothing casts query params here; `type: :boolean` in the OpenAPI op silently no-ops `?flag=1`) → `docs/context/derived-vs-marker-folders.md`
- Mobile keyboard toolbar — why it hides on some phones, the decoy Yjs UndoManager, caret-after-insert → `docs/context/mobile-editor-toolbar.md`
- Writing a CM6 live-preview decoration (lezer reads `[!type]` as a Link; one highlight tag serves many nodes; `syntaxTree` is lazy) → `docs/context/codemirror-live-preview-extensions.md`
- A route guard or view acts on state that mutations definitely updated (user bounced back to a completed onboarding/wizard step; loop only a full page reload escapes) → `docs/context/bootstrap-seed-cache-dual-authority.md`
- A mutation's caller navigates to a page that reads `gate_ok` (MCP-first signup lands on `/` instead of consent Approve; `invalidateQueries(["onboarding","status"])` must be AWAITED) → `docs/context/onboarding-status-refetch-race.md`
- Adding a shadcn/Base UI component (popup untappable inside a Radix sheet on mobile, field unnamed while the list is open, SPA-wide 504 `Outdated Optimize Dep` after a `bun remove`, `fireEvent.click` won't open a combobox) → `docs/context/shadcn-combobox-adoption.md`

**Issue tracker**
- An old issue's description contradicts the code, or you are triaging a stale backlog (`Refs #N` drift + the detection recipe) → `docs/context/backlog-refs-drift.md`

**Testing & CI**
- Full test strategy, ExUnit tooling, CI pipeline → `docs/context/testing-strategy.md`
- CI pipeline & gating — what runs vs what gates, post testing-architecture migration → `docs/context/ci-pipeline-gating.md`
- Running the ExUnit suite locally against Docker Postgres → `docs/context/local-backend-testing.md`
- `Vault not registered after 15s` E2E diagnostic ladder — don't just bump the timeout → `docs/context/e2e-vault-registration-diagnostics.md`
- `Application.put_env` in `async: true` tests is a flake source (fix the mutator, or route the read through `Engram.ServiceConfig` per-process overrides) → `docs/context/exunit-application-env-races.md`
- Writing a test that proves a query is tenant-scoped (only INSERT raises; the suite connects as a SUPERUSER; use `Engram.RlsCase` + a zero-rows CONTROL test) → `docs/context/rls-enforcement-testing-traps.md`
- An e2e assertion counts something vault-wide, or a test's failure count refuses to move across product fixes (the e2e vault is session-scoped and shared by ~110 tests) → `docs/context/e2e-session-vault-scoping-trap.md`
- Several unrelated `e2e-crdt` tests fail in one run (live-binding + seq-gap-heal + orphaned-claim + web-to-obsidian): check whether both Obsidian instances died mid-run before counting N bugs → `docs/context/e2e-simultaneous-failures-obsidian-death.md`
- A CDP call starts returning `[Errno 111] Connection refused`, or a "content never propagated" 120s timeout while the backend log stays healthy: read `obsidian-stderr-*.log` / `host-forensics.log` for the OOM kill → `docs/context/e2e-simultaneous-failures-obsidian-death.md`
- Deciding whether a red e2e run is a real regression (same test passing on the SAME sha in a sibling run; check the pinned PLUGIN sha too) → `docs/context/e2e-simultaneous-failures-obsidian-death.md`
- Why `prebuild-mix` recompiled everything despite cache hits (absolute-path compile manifest) → `docs/context/ci-mix-compile-cache-runner-path.md`
- Bun lifecycle-script trust model, `trustedDependencies`, the pngquant CI flake (#975) → `docs/context/bun-postinstall-trust.md`
- Red `e2e-clerk`: which failures are REAL bugs vs load vs a lying oracle → `docs/context/e2e-clerk-failure-taxonomy.md`
- All e2e modal tests fail "Modal option not found" (stranded sync-preview modal cascade) → `docs/context/e2e-sync-preview-modal-cascade.md`
- Playwright clicks hang / headless Chromium renders no frames on the dev box → `docs/context/headless-chromium-no-raf-playwright.md`
- Changing the headless CRDT test tier, or `main.ts`'s CRDT lifecycle (the headless harness must mirror it) → `docs/context/headless-harness-mirrors-main-ts.md`
- Testing-architecture migration record: report-only e2e, the flake ledger, why the gate is deterministic → `docs/context/testing-architecture-migration.md`
- The e2e harness is an API consumer. Before changing any endpoint contract (caps, status codes, param semantics), grep `e2e/` and `frontend/e2e/`, not just `frontend/src` and the plugin. A 500-id 422 cap on batch-delete once broke e2e teardowns that send 1000+ ids. Remaining caps: notes `batch_upsert` 500 (encrypt + CRDT merge per entry), attachments `batch_delete` 500.
- Adding a fast mode to a fingerprinted CI job, widening a cache restore-key, or a job reads a file in no fingerprint group → `docs/context/ci-fingerprint-markers.md`
- CI registry `:5001` refused or `manifest unknown` after a prune, or changing CI registry retention/GC (marker window < image window, never GC near a push) → `docs/context/ci-registry-down-during-appdata-backup.md`
- A `Post <name>` cache step takes 10-15 min, or adding a cache / image-push target in CI (runs-on/cache only; NO_PROXY for push hosts) → `docs/context/github-cache-upload-cliff.md`
- "Checkout plugin" slow/hung, CI Postgres unhealthy on `gamingpc-*`, Clerk 429 in e2e-browser, lychee sentry.io refused, a job with a step stuck `in_progress` and no log, or infra `assert-main-tip` red (credentialed git URLs bypass git_cdn; tmpfs every CI Postgres) → `docs/context/ci-runner-network-and-disk-gotchas.md`
- Touching sobelow or `.sobelow-skips`, or regenerating skips after a line shift (fingerprints defend locations not provenance; `rm` before `--mark-skip-all`) → `docs/context/sobelow-silent-no-op-and-fingerprint-skips.md`

**Deploy & Infra**
- AWS ECS deploy, backups, observability, security checklist → `docs/context/deploy-prod.md`
- `git push` of a `release-v*` tag is rejected as `already exists` (release-please cuts the tag itself on release-PR merge), or `deploy-prod.yml` / `terraform apply` is green and you are about to call prod deployed (neither waits for the ECS rollout), or verifying a rollout/WORKER tier without AWS credentials, or Loki's newest line stopped after a deploy → `docs/context/deploy-prod.md`
- Checking whether a frontend change shipped by grepping the deployed SPA, or a `version` field that won't move after a deploy (the entry bundle proves nothing — routes are lazy chunks; trust `build_sha`) → `docs/context/frontend-ship-verification-bundle-grep.md`
- Expecting a main merge to move prod frontend traffic (`deploy-frontend` only uploads a zero-traffic version; only `frontend-promote.yml` shifts traffic) → `docs/context/frontend-ship-verification-bundle-grep.md`
- Launch-minimum DR runbook — RDS snapshots, S3 versioning, Qdrant reindex fallback → `docs/context/disaster-recovery.md`
- Why `_build` cache mount across Docker RUN steps ships stale beams → `docs/context/docker-build-cache-pitfalls.md`
- Local dev loop, hot reload, IEx tricks → `docs/context/dev-iteration-loop.md`
- Local Qdrant dies mid-upsert with `Req.TransportError: socket closed` while `docker inspect` still says healthy (SIGILL, not OOM — this host has no AVX2; read `RestartCount`, not `oom`) → `docs/context/local-qdrant-sigill-no-avx2.md`
- PG18/UUIDv7 prod crash-loop root cause — in-place engine bump vs specced taint+recreate; `verify_schema_baseline/0` guard → `docs/context/pg18-uuidv7-prod-crashloop-2026-06-11.md`
- `mjml` vs `lingua` rustler_precompiled version conflict — pin override → `docs/context/rustler-precompiled-nif-conflict.md`
- Worktree compile fails on a dep module "not available" (`expo_po_parser`, `Hammer`); `mix deps.compile X` without `--force` silently no-ops; hardlinked `deps/` can omit yecc/leex-generated beams → `docs/context/worktree-deps-artifact-staleness.md`
- `git push` from a worktree hangs or is rejected at the pre-push gates, `mix` reports `erts-14`/OTP 26, or `:opentelemetry` fails with `missing_module,opentelemetry_sup` (bare push runs the gates on the system OTP; always `mise exec -- git push`) → `docs/context/worktree-push-otp-mismatch-rebar-dep.md`
- ExAws KMS traps (key-first args, manual base64, scope creds to `:ex_aws, :kms` or S3 auth silently breaks), plus the Tier-4 / Phase F provider-routing roadmap → `docs/context/aws-kms-provider-integration.md`

**Encryption**
- Runbooks: per-user DEK rotation (T3.7) + half-state recovery, master-key rotation (staging/self-host only; prod is KMS) → `docs/context/encryption-operations.md`. The content-hash HMAC backfill was removed 2026-10-06 (prod at zero; see "Pruned" in `docs/context/data-migrations-ledger.md`)
- Invalid UTF-8 at rest (bytea bypasses PG validation) → `Jason.encode` 500 at every JSON egress; fix + backfill task → `docs/context/invalid-utf8-at-rest-json-500.md`

**Perf & Quality**
- Read-path decrypt perf — parallel_map economics, when it helps vs hurts → `docs/context/read-path-decrypt-perf.md`
- Perf caches + invalidation contracts (2026-06-12 audit wave) → `docs/context/perf-caching-invalidation.md`
- Replacing hand-rolled code with a shared helper (consolidating a PARSER silently drops accepted input shapes no test names — CRLF frontmatter read as "no frontmatter"), or a log metadata key built inside a helper that Credo cannot see → `docs/context/consolidation-drops-undocumented-tolerances.md`
- Adding/reading a WebSocket metric, or a socket panel reads No data (`EngramWeb.Telemetry.metrics/0` never reaches Prometheus; Phoenix encodes a broadcast once per serializer; ChannelTest bypasses the serializer) → `docs/context/websocket-metrics.md`

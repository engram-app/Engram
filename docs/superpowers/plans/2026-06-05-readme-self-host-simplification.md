# README + Self-Host Onramp Simplification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the self-host onramp from a 9-way choice (3 compose presets × 3 `.env` examples) plus a 339-line README to a single 4-command path with one README, one `.env.example`, and one `docker-compose.yml` (with `--profile s3` for MinIO opt-in).

**Architecture:** No app-code changes. Pure docs + ops-config consolidation. The new default is the current "lite" shape (Ollama embeddings + Postgres `bytea` attachments). MinIO becomes an opt-in compose profile. Voyage AI becomes an `.env` switch documented inline. Educational content (architecture, MCP, API reference, dev quick start) moves to the existing pages on `engram.page/docs/*` and to `CONTRIBUTING.md`.

**Tech Stack:** Docker Compose (v2.3+ for `profiles:`), Markdown, conventional commits.

**Spec:** `docs/superpowers/specs/2026-06-05-readme-self-host-simplification-design.md`

**Branch:** `docs/readme-self-host-simplification` (worktree at `.worktrees/docs-readme-self-host`)

---

## File Map

Files this plan touches (in execution order):

| File | Action | Why |
|---|---|---|
| `.gitignore` | Modify | Drop unignore lines for files about to be deleted; keep `!.env.example` |
| `.env.example` | Rewrite (in place) | Default to `STORAGE_BACKEND=database`; rewrite "Attachment storage" comment for `--profile s3`; add MinIO threshold guidance; update copy-instructions header |
| `.env.lite.example` | Delete | Becomes the default (folded into rewritten `.env.example`) |
| `.env.voyage.example` | Delete | Voyage is a commented `.env.example` block + a docs link |
| `.env.elixir.example` | Delete | Dev-only; covered in `CONTRIBUTING.md` after this PR |
| `.env.deploy` | Move → `scripts/deploy.env` | Internal FastRaid deploy, not for self-hosters; off the root |
| `docker-compose.yml` | Restructure | Make bytea default; put MinIO behind `profiles: [s3]`; drop minio-init from engram's `depends_on:`; rewrite header comment |
| `docker-compose.lite.yml` | Delete | Folded into the new `docker-compose.yml` default |
| `docker-compose.voyage.yml` | Delete | Voyage no longer has its own preset |
| `CONTRIBUTING.md` | Restructure | Absorb dev quick start + testing sections from old README; remove the line that points back at README |
| `README.md` | Rewrite | ~70 lines, self-host first, doc-link table, license/security/contributing pointers; six shield badges preserved verbatim |
| `mix.exs` | Bump version | `0.5.350 → 0.5.351`. Pre-push hook enforces this for user-visible changes |

Files this plan **does NOT** touch (out of scope):
- `docker-compose.dev.yml`, `docker-compose.elixir.yml`, `docker-compose.ci*.yml`, `docker-compose.parity.yml` — non-self-host
- `.env`, `.env.dev`, `.env.local*`, `.env.elixir` — local untracked working state (already gitignored)
- Any app code under `lib/`, `test/`, `priv/`, `frontend/`
- Marketing docs (separate sibling PR on `engram-app/engram-marketing` — Task 11)

---

## Task 1: Update `.gitignore` (drop unignore lines for deleted examples)

**Files:**
- Modify: `.gitignore` (lines 1, 3, 45, 46)

`.gitignore` currently `!`-unignores each tracked `.env.*.example` individually. The three we're deleting need their lines removed so they don't accidentally come back. `!.env.example` stays.

- [ ] **Step 1: Open `.gitignore` and confirm current state**

Run: `head -3 .gitignore && sed -n '44,47p' .gitignore`

Expected exactly:
```
# Environment (keep .env.elixir.example as canonical template)
.env*
!.env.elixir.example
!.env.example
!.env.lite.example
!.env.voyage.example
```

If it diverges (e.g., main moved while you weren't looking), stop and re-baseline.

- [ ] **Step 2: Edit the comment on line 1**

Change:
```
# Environment (keep .env.elixir.example as canonical template)
```
to:
```
# Environment (keep .env.example as canonical template)
```

- [ ] **Step 3: Remove the three unignore lines**

Delete these three lines:
```
!.env.elixir.example
!.env.lite.example
!.env.voyage.example
```

Keep `!.env.example`.

- [ ] **Step 4: Verify final state**

Run: `grep -nE '^!\.env' .gitignore`

Expected output (exactly one line):
```
N:!.env.example
```
where `N` is the line number — must be the only `!` line for `.env*`.

- [ ] **Step 5: Commit**

```bash
git add .gitignore
git commit -m "chore: drop gitignore unignore lines for env examples being removed"
```

---

## Task 2: Rewrite `.env.example` for bytea-default + MinIO threshold guidance

**Files:**
- Modify: `.env.example` (full rewrite preserving existing optional-block structure)

The new file flips the attachment default from `s3` to `database` and rewrites the storage section to describe the `--profile s3` opt-in. Other sections (Voyage commented switch, Sentry, Resend, PostHog, Cloudflare Analytics, AWS KMS) stay as commented blocks — they're useful and already documented well.

- [ ] **Step 1: Replace the entire file contents**

Write `.env.example` with this exact content:

```env
# Engram self-host configuration. Copy to .env and fill in the three secrets
# below. Defaults are wired for the docker-compose.yml stack and work as-is.
#
#   cp .env.example .env
#
# Do NOT commit .env — it holds your secrets.
#
# Service addressing (DATABASE_URL, QDRANT_URL, OLLAMA_URL, STORAGE_HOST) is
# set by docker-compose.yml to match the container network; you don't set it
# here.

# ─── Required secrets ───────────────────────────────────────────────────────
# Generate each with the command shown, then paste the value.

# openssl rand -base64 48
SECRET_KEY_BASE=

# openssl rand -base64 48
JWT_SECRET=

# 32-byte key, base64-encoded:  openssl rand -base64 32
# Losing this makes every encrypted note unrecoverable — back it up.
ENCRYPTION_MASTER_KEY=

# ─── Host ────────────────────────────────────────────────────────────────────
# Public hostname. The first entry is canonical (URLs, emails); all entries are
# added to the CORS + WebSocket allowlist. Comma-separated, ports allowed.
# Examples: localhost  |  engram.example.com  |  engram.example.com,10.0.20.5:4000
PHX_HOST=localhost

# Scheme + port used when BUILDING advertised URLs (OAuth/MCP discovery
# documents, device-flow links, email links). The release runs in prod mode,
# which defaults these to https / 443 — correct when you're behind a TLS
# reverse proxy (the normal setup). For a plain-http trial on localhost, set
# both so the advertised URLs match where the app actually listens:
#   PHX_SCHEME=http
#   PHX_PORT=4000

# ─── Auth ──────────────────────────────────────────────────────────────────
# local = built-in email/password (zero third-party config). clerk = SaaS JWKS.
AUTH_PROVIDER=local

# Registration mode. Default is invite_only — first user becomes admin, then
# subsequent signups need an invite. Set "open" for a public instance or to
# let a friend self-serve during a demo. "closed" disables signup entirely.
ENGRAM_DEFAULT_REGISTRATION_MODE=open

# ─── Encryption key provider ─────────────────────────────────────────────────
# local = ENCRYPTION_MASTER_KEY above. aws_kms = managed CMK (needs AWS_* vars).
KEY_PROVIDER=local

# ─── Embedding ───────────────────────────────────────────────────────────────
# Default: local Ollama (no API key, runs in the stack). The ollama-init
# service pulls nomic-embed-text on first `up`.
EMBED_BACKEND=ollama
EMBED_MODEL=nomic-embed-text
EMBED_DIMS=768

# To use Voyage AI instead (better quality, needs an API key + outbound calls):
#   EMBED_BACKEND=voyage
#   EMBED_MODEL=voyage-4-large
#   EMBED_DIMS=1024
#   VOYAGE_API_KEY=
#   DOC_EMBED_MODEL=voyage-4-large    # optional asymmetric retrieval
#   QUERY_EMBED_MODEL=voyage-4-lite
# Docs: https://engram.page/docs/self-host/environment-variables/#embeddings

# ─── Vector store (Qdrant) ───────────────────────────────────────────────────
QDRANT_COLLECTION=obsidian_notes
# Binary quantization needs an AVX2-capable CPU. Disable on older hardware:
#   QDRANT_BINARY_QUANTIZATION=false

# ─── Attachment storage ──────────────────────────────────────────────────────
# Default: store attachments in Postgres bytea — no MinIO container, smallest
# stack. Good for most self-host vaults.
#
# When to switch to MinIO/S3:
#   - Single attachment > ~50 MB (videos, big PDFs), or
#   - Total attachment storage > ~10 GB, or
#   - You want to point Engram at an existing S3 bucket (AWS / R2 / etc.).
#
# To switch: set STORAGE_BACKEND=s3 below, fill in the STORAGE_* creds, AND
# start the stack with the s3 profile so the MinIO container runs:
#
#   docker compose --profile s3 up -d
#
# Docs: https://engram.page/docs/self-host/environment-variables/#storage
STORAGE_BACKEND=database

# Used when STORAGE_BACKEND=s3 (ignored otherwise).
# STORAGE_BUCKET=engram-attachments
# STORAGE_ACCESS_KEY_ID=minioadmin
# STORAGE_SECRET_ACCESS_KEY=minioadmin
# STORAGE_REGION=us-east-1

# ─── Optional: reranker (Jina) ───────────────────────────────────────────────
#   RERANKER_BACKEND=jina
#   JINA_URL=

# ─── Optional: transactional email (Resend) ──────────────────────────────────
#   RESEND_API_KEY=
#   EMAIL_FROM=you@example.com

# ─── Optional: AWS KMS key provider (KEY_PROVIDER=aws_kms) ────────────────────
#   AWS_KMS_KEY_ID=
#   AWS_REGION=
#   AWS_ACCESS_KEY_ID=
#   AWS_SECRET_ACCESS_KEY=

# ─── Optional: Sentry error reporting ────────────────────────────────────────
#   Backend (Elixir SDK; no-op when unset):
#     SENTRY_DSN=
#   Frontend (Vite build env; no-op when unset, baked into bundle at build):
#     VITE_SENTRY_DSN=
#     VITE_GIT_SHA=<7-char SHA>   # release tag for source-map symbolication
#   CI-only (source-map upload at build):
#     SENTRY_AUTH_TOKEN=
#     SENTRY_ORG=engram-app
#     SENTRY_PROJECT=engram-frontend

# ─── Optional: Cloudflare Web Analytics (cookieless RUM) ─────────────────────
#   Vite build env (no-op when unset; baked into bundle):
#     VITE_CF_BEACON_TOKEN=<32-char hex from CF dashboard>
#   Self-host builds leave it unset → no beacon, no telemetry to engram's CF
#   account.

# ─── Optional: PostHog product analytics ─────────────────────────────────────
#   Backend (Elixir wrapper; no-op when unset):
#     POSTHOG_API_KEY=phc_…            # project token (write-only ingest)
#     POSTHOG_HOST=https://us.i.posthog.com   # or https://eu.i.posthog.com
#   Frontend (Vite build env; no-op when unset, baked into bundle):
#     VITE_POSTHOG_KEY=phc_…
#     VITE_POSTHOG_HOST=https://us.i.posthog.com
#   Self-host leaves all four unset → no telemetry to engram's PostHog account.
#   Autocapture is hard-coded OFF; explicit events only.
```

- [ ] **Step 2: Verify default is `database`**

Run: `grep -E '^STORAGE_BACKEND' .env.example`

Expected: `STORAGE_BACKEND=database` (no other uncommented `STORAGE_BACKEND` line).

- [ ] **Step 3: Verify MinIO command is documented**

Run: `grep -F 'docker compose --profile s3 up' .env.example`

Expected: at least one match.

- [ ] **Step 4: Commit**

```bash
git add .env.example
git commit -m "feat(self-host): default .env.example to bytea attachments + document --profile s3"
```

---

## Task 3: Delete `.env.lite.example`, `.env.voyage.example`, `.env.elixir.example`

**Files:**
- Delete: `.env.lite.example`
- Delete: `.env.voyage.example`
- Delete: `.env.elixir.example`

- [ ] **Step 1: Confirm no in-tree references remain**

Run:
```bash
git grep -nE '\.env\.(lite|voyage|elixir)\.example' -- ':!docs/superpowers/'
```

Expected: empty output (or only matches inside `.gitignore` if Task 1 was skipped — in which case stop and run Task 1).

If matches appear in any tracked file outside the spec/plan directory, halt and patch those references in this task before deleting.

- [ ] **Step 2: Delete the three files**

```bash
git rm .env.lite.example .env.voyage.example .env.elixir.example
```

- [ ] **Step 3: Verify deletion**

Run: `ls .env.* 2>/dev/null`

Expected: only `.env.example` (and any untracked local-state files like `.env`, `.env.local`, `.env.dev`, which are fine — they're gitignored).

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: delete .env.lite.example, .env.voyage.example, .env.elixir.example

Consolidated into the single .env.example. Voyage is a commented switch
inside .env.example with a docs link; the dev-contributor env lives in
CONTRIBUTING.md after this PR."
```

---

## Task 4: Restructure `docker-compose.yml` (bytea default + `--profile s3` for MinIO)

**Files:**
- Modify: `docker-compose.yml` (full rewrite)

Changes from current:
1. Rewrite the header comment to describe the new default + `--profile s3` opt-in.
2. Drop `minio-init` from engram's `depends_on:` (so engram can boot without the s3 profile active). MinIO bucket creation still happens via `minio-init` when `--profile s3` is used; engram's first attachment write doesn't happen at boot, so there's no race in practice.
3. Add `profiles: [s3]` to the `minio` and `minio-init` services.
4. Leave engram's `STORAGE_SCHEME`/`STORAGE_HOST`/`STORAGE_PORT` env in place — they're inert when `STORAGE_BACKEND=database`, and they're correct when `STORAGE_BACKEND=s3` + `--profile s3` is up.
5. Keep the `minio_data` volume declared — an unused declared volume costs nothing.

- [ ] **Step 1: Replace the entire file contents**

Write `docker-compose.yml` with this exact content:

```yaml
# Engram self-host stack — canonical quickstart.
#
#   cp .env.example .env       # fill in the three generated secrets at top
#   docker compose up -d       # first build compiles the release (~few min)
#
# Default = Ollama embeddings + Postgres bytea attachments. Only port 4000
# is host-exposed; Postgres, Qdrant, and Ollama stay on the private network.
# The app runs DB migrations on boot (see entrypoint.sh) before serving.
#
# For large vaults (videos, big PDFs, > ~10 GB attachments) switch to MinIO
# for S3-style object storage:
#
#   1) In .env, set STORAGE_BACKEND=s3 and uncomment the STORAGE_* lines.
#   2) Bring the stack up WITH the s3 profile so the MinIO container runs:
#
#        docker compose --profile s3 up -d
#
# Service-to-service addressing (DATABASE_URL, *_URL, STORAGE_HOST) is fixed
# in `environment:` below because it must match the service names on this
# network — do not move it to .env. Everything a self-hoster actually tunes
# (secrets, embedding backend, storage creds) lives in .env.

services:
  engram:
    build: .
    env_file: .env
    environment:
      # Docker-internal wiring — points at the service names on this network.
      DATABASE_URL: postgresql://engram:engram@postgres:5432/engram
      QDRANT_URL: http://qdrant:6333
      OLLAMA_URL: http://ollama:11434
      # S3 addressing — inert when STORAGE_BACKEND=database, correct when =s3.
      STORAGE_SCHEME: "http://"
      STORAGE_HOST: minio
      STORAGE_PORT: "9000"
    ports:
      - "4000:4000"
    depends_on:
      postgres:
        condition: service_healthy
      qdrant:
        condition: service_started
      ollama:
        condition: service_healthy
      ollama-init:
        condition: service_completed_successfully
    healthcheck:
      # So `docker compose up` reports ready only after the release has booted
      # + migrated and the endpoint is listening — not the instant the process
      # forks. start_period covers release migrate + Phoenix listen.
      test: ["CMD-SHELL", "curl -sf http://localhost:4000/api/health || exit 1"]
      start_period: 30s
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: engram
      POSTGRES_PASSWORD: engram
      POSTGRES_DB: engram
    volumes:
      - pg_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U engram"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  qdrant:
    image: qdrant/qdrant:v1.17.1
    volumes:
      - qdrant_data:/qdrant/storage
    restart: unless-stopped

  ollama:
    image: ollama/ollama:latest
    volumes:
      - ollama_data:/root/.ollama
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  # One-shot: pull the default self-host embedding model so the first note
  # indexes without a manual step. Exits 0 once the model is present.
  ollama-init:
    image: ollama/ollama:latest
    depends_on:
      ollama:
        condition: service_healthy
    environment:
      OLLAMA_HOST: http://ollama:11434
    entrypoint: ["/bin/sh", "-c"]
    command: ["ollama pull nomic-embed-text"]
    restart: "no"

  # MinIO — opt-in via `--profile s3`. Off by default.
  minio:
    profiles: [s3]
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      # Kept in sync with the engram app's STORAGE_* creds via .env defaults.
      MINIO_ROOT_USER: ${STORAGE_ACCESS_KEY_ID:-minioadmin}
      MINIO_ROOT_PASSWORD: ${STORAGE_SECRET_ACCESS_KEY:-minioadmin}
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "mc", "ready", "local"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  # One-shot: create the attachments bucket, then exit. Opt-in with MinIO.
  minio-init:
    profiles: [s3]
    image: minio/mc:latest
    depends_on:
      minio:
        condition: service_healthy
    entrypoint: >
      /bin/sh -c "
      mc alias set local http://minio:9000 ${STORAGE_ACCESS_KEY_ID:-minioadmin} ${STORAGE_SECRET_ACCESS_KEY:-minioadmin};
      mc mb --ignore-existing local/${STORAGE_BUCKET:-engram-attachments};
      exit 0;
      "
    restart: "no"

volumes:
  pg_data:
  qdrant_data:
  ollama_data:
  minio_data:
```

- [ ] **Step 2: Validate the YAML with `docker compose config` (default profile)**

Run:
```bash
docker compose config --quiet
```

Expected: exit code 0, no output. (`--quiet` suppresses the rendered output; non-zero exit indicates a syntax or reference error.)

- [ ] **Step 3: Validate the s3 profile resolves**

Run:
```bash
docker compose --profile s3 config --services
```

Expected output (one service per line, order may vary):
```
engram
postgres
qdrant
ollama
ollama-init
minio
minio-init
```

- [ ] **Step 4: Confirm default profile excludes MinIO**

Run:
```bash
docker compose config --services
```

Expected output (no `minio` or `minio-init`):
```
engram
postgres
qdrant
ollama
ollama-init
```

- [ ] **Step 5: Confirm engram has no `minio-init` dependency in the default profile**

Run:
```bash
docker compose config | grep -A6 'engram:' | grep -A4 depends_on
```

Expected: `minio-init:` does NOT appear in engram's resolved `depends_on:`.

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml
git commit -m "feat(self-host): bytea default + MinIO behind --profile s3

Removes engram's depends_on minio-init so the default stack boots without
MinIO. minio + minio-init now carry profiles: [s3] and only run when the
operator opts in with docker compose --profile s3 up."
```

---

## Task 5: Delete `docker-compose.lite.yml` and `docker-compose.voyage.yml`

**Files:**
- Delete: `docker-compose.lite.yml`
- Delete: `docker-compose.voyage.yml`

- [ ] **Step 1: Confirm no in-tree references remain**

Run:
```bash
git grep -nE 'docker-compose\.(lite|voyage)\.yml' -- ':!docs/superpowers/'
```

Expected: empty output (Task 4's rewrite removed any references in `docker-compose.yml` comments and Task 1/2/3 cleaned `.env.example` + `.gitignore`).

If matches appear in tracked files outside `docs/superpowers/`, halt and patch them before deleting.

- [ ] **Step 2: Delete**

```bash
git rm docker-compose.lite.yml docker-compose.voyage.yml
```

- [ ] **Step 3: Verify**

Run: `ls docker-compose*.yml`

Expected (5 remaining — the dev/CI files are out of scope):
```
docker-compose.ci-database.yml
docker-compose.ci-local.yml
docker-compose.ci.yml
docker-compose.dev.yml
docker-compose.elixir.yml
docker-compose.parity.yml
docker-compose.yml
```

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: delete docker-compose.lite.yml + docker-compose.voyage.yml

Folded into docker-compose.yml (default = bytea; MinIO via --profile s3).
Voyage AI is an .env switch documented inline + on the marketing docs."
```

---

## Task 6: Move `.env.deploy` → `scripts/deploy.env`

**Files:**
- Move: `.env.deploy` → `scripts/deploy.env`

`scripts/` exists. `.env.deploy` has zero references anywhere in the repo (verified during planning recon). Any external ops automation pointing at the path is private to the operator's machine and outside repo scope.

- [ ] **Step 1: Confirm zero in-repo references to `.env.deploy`**

Run:
```bash
git grep -nE '\.env\.deploy' -- ':!docs/superpowers/'
```

Expected: empty.

- [ ] **Step 2: Move**

```bash
git mv .env.deploy scripts/deploy.env
```

- [ ] **Step 3: Verify**

Run: `ls .env.deploy 2>/dev/null; ls scripts/deploy.env`

Expected: first line empty (file gone from root), second line shows `scripts/deploy.env`.

- [ ] **Step 4: Commit**

```bash
git commit -m "chore: move .env.deploy to scripts/deploy.env

Internal FastRaid deploy config — not for self-hosters. Off the repo root
so first-time readers don't have to wonder what it does."
```

---

## Task 7: Update `CONTRIBUTING.md` (absorb dev quick start + testing)

**Files:**
- Modify: `CONTRIBUTING.md`

The old README has a "Development Quick Start" (lines 117-216 of pre-this-PR README) and "Testing" (lines 306-316). Both move here. The current `CONTRIBUTING.md:53-55` line pointing back at README's Quick Start gets replaced.

- [ ] **Step 1: Replace the "Development setup" section with a real Local development section**

Open `CONTRIBUTING.md`. Find the section starting at line 52:
```
## Development setup

See [README.md](README.md) "Quick Start" for local environment setup, and
[CLAUDE.md](CLAUDE.md) for architecture and workflow details.
```

Replace it with:

````markdown
## Local development

For running Engram against a local stack (Postgres + Qdrant + Ollama)
without Docker — i.e. you're hacking on the app itself.

### Prerequisites

- Elixir 1.17+ and Erlang/OTP 27+
- PostgreSQL 16+
- [Qdrant](https://qdrant.tech) running locally or Qdrant Cloud
- [Ollama](https://ollama.com) (optional — only if running embeddings locally;
  the alternative is `EMBED_BACKEND=voyage` with a Voyage API key)

### Setup

```bash
mix deps.get
mix ecto.setup                  # create DB + migrations + seeds
bash scripts/install-hooks.sh   # one-time: enables pre-push version check
```

### Configure

```bash
cp .env.example .env
```

Edit `.env`. Minimum for local dev:

```bash
DATABASE_URL=postgresql://engram:engram@localhost:5432/engram
EMBED_BACKEND=ollama
EMBED_MODEL=nomic-embed-text
EMBED_DIMS=768
QDRANT_URL=http://localhost:6333
JWT_SECRET=some-random-string-at-least-32-chars
SECRET_KEY_BASE=$(openssl rand -base64 48)
ENCRYPTION_MASTER_KEY=$(openssl rand -base64 32)
PHX_HOST=localhost
PHX_SCHEME=http
PHX_PORT=4000
```

Full env reference: <https://engram.page/docs/self-host/environment-variables/>.

### Start

```bash
mix phx.server   # http://localhost:4000
```

### Smoke-test the dev server

Register, log in, create an API key, push a note, search:

```bash
# Register
curl -X POST http://localhost:4000/api/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "password": "your-password"}'

# Login → JWT
TOKEN=$(curl -s -X POST http://localhost:4000/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "password": "your-password"}' \
  | jq -r '.token')

# Create API key
curl -X POST http://localhost:4000/api/api-keys \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "dev-key"}'
```

Save the `engram_…` API key — only shown once.

### Tests

```bash
mix test                                    # unit tests
python3 -m pytest e2e/tests/ -v             # E2E (needs CI stack + Obsidian)
```

See `docs/context/testing-strategy.md` for the full testing strategy and
`CLAUDE.md` for architecture and workflow details.
````

- [ ] **Step 2: Verify the back-reference to README's Quick Start is gone**

Run:
```bash
grep -F 'Quick Start' CONTRIBUTING.md
```

Expected: empty (we're killing the README→CONTRIBUTING→README loop).

- [ ] **Step 3: Commit**

```bash
git add CONTRIBUTING.md
git commit -m "docs(contributing): absorb dev quick start + testing from README

CONTRIBUTING.md now owns the local-dev setup; README will point here in
the next commit. Inverts the previous README↔CONTRIBUTING loop."
```

---

## Task 8: Rewrite `README.md`

**Files:**
- Modify: `README.md` (full rewrite)

Preserves the six shield badges added in PR #469 verbatim. Target length ~70 lines.

- [ ] **Step 1: Capture the current shield block verbatim**

Run:
```bash
sed -n '1,8p' README.md
```

Confirm output is exactly:
```
# Engram

[![Verify](https://github.com/engram-app/Engram/actions/workflows/verify.yml/badge.svg)](https://github.com/engram-app/Engram/actions/workflows/verify.yml)
[![Last commit](https://img.shields.io/github/last-commit/engram-app/Engram)](https://github.com/engram-app/Engram/commits/main)
[![Stars](https://img.shields.io/github/stars/engram-app/Engram?style=flat)](https://github.com/engram-app/Engram/stargazers)
[![License](https://img.shields.io/badge/license-PolyForm_SB_1.0-blue)](LICENSE)
[![Sponsor](https://img.shields.io/github/sponsors/engram-app?label=Sponsor&logo=GitHub&color=ea4aaa)](https://github.com/sponsors/engram-app)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Buy_a_coffee-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/engrams_sync)
```

If it differs, copy the actual block you see — main may have moved.

- [ ] **Step 2: Replace `README.md` with the new content**

Write the file with this exact content (substituting the verbatim shield block from Step 1 if it changed):

```markdown
# Engram

[![Verify](https://github.com/engram-app/Engram/actions/workflows/verify.yml/badge.svg)](https://github.com/engram-app/Engram/actions/workflows/verify.yml)
[![Last commit](https://img.shields.io/github/last-commit/engram-app/Engram)](https://github.com/engram-app/Engram/commits/main)
[![Stars](https://img.shields.io/github/stars/engram-app/Engram?style=flat)](https://github.com/engram-app/Engram/stargazers)
[![License](https://img.shields.io/badge/license-PolyForm_SB_1.0-blue)](LICENSE)
[![Sponsor](https://img.shields.io/github/sponsors/engram-app?label=Sponsor&logo=GitHub&color=ea4aaa)](https://github.com/sponsors/engram-app)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-Buy_a_coffee-FF5E5B?logo=ko-fi&logoColor=white)](https://ko-fi.com/engrams_sync)

Your notes are your AI's memory.

The AI memory layer where your notes are the storage — markdown you and your AI
assistants both read and write to via [MCP](https://modelcontextprotocol.io).
Built with Elixir/Phoenix. Pairs with the
[Engram Obsidian Sync](https://github.com/engram-app/Engram-obsidian) plugin
for real-time bidirectional sync.

## Self-Host (Docker Compose)

```bash
git clone https://github.com/engram-app/Engram.git
cd Engram
cp .env.example .env       # then fill in the three secrets at the top
docker compose up -d
```

App at <http://localhost:4000>. Migrations run on boot. Only port 4000 is
host-exposed; everything else stays on the private Docker network.

**Large vaults?** Enable MinIO for S3-style attachments:
`docker compose --profile s3 up -d` — see
[storage docs](https://engram.page/docs/self-host/environment-variables/#storage).

**Better embeddings?** Switch to Voyage AI in `.env` — see
[embeddings docs](https://engram.page/docs/self-host/environment-variables/#embeddings).

### Full self-host documentation

| Topic | Link |
|---|---|
| Quickstart           | <https://engram.page/docs/self-host/quickstart/> |
| Environment vars     | <https://engram.page/docs/self-host/environment-variables/> |
| Encryption & keys    | <https://engram.page/docs/self-host/encryption/> |
| Backup & restore     | <https://engram.page/docs/self-host/backup-restore/> |
| Upgrades             | <https://engram.page/docs/self-host/upgrade/> |
| Troubleshooting      | <https://engram.page/docs/self-host/troubleshooting/> |
| Architecture         | <https://engram.page/docs/self-host/architecture/> |
| MCP setup            | <https://engram.page/docs/mcp/> |
| HTTP API             | <https://engram.page/docs/api/> |

## Contributing

Local dev setup, tests, and PR rules: see [CONTRIBUTING.md](./CONTRIBUTING.md).

## License

Dual-licensed:
- **[PolyForm Small Business 1.0.0](./LICENSE)** — free for organizations
  under $1M USD prior-year revenue and < 100 employees + contractors.
- **Commercial License** — required for larger orgs. See
  [LICENSE-COMMERCIAL.md](./LICENSE-COMMERCIAL.md) or email
  `support@engram.page`.

External contributions sign the [Engram CLA](./.github/CLA.md). See
[CONTRIBUTING.md](./CONTRIBUTING.md).

## Security

See [SECURITY.md](./SECURITY.md) for vulnerability disclosure. Self-host LAN
deployments are out of scope of our published SLA — security depends on the
operator's network and infra.

Copyright (c) 2026 Rasbandit Software Solutions LLC d/b/a Engram.
```

- [ ] **Step 3: Verify length and core content**

Run:
```bash
wc -l README.md
grep -F 'docker compose up -d' README.md
grep -F 'engram.page/docs/' README.md | wc -l
```

Expected:
- `wc -l README.md`: ≤ 75 lines
- `docker compose up -d` match found
- `engram.page/docs/` link count: at least 9

- [ ] **Step 4: Verify no stale references to deleted files**

Run:
```bash
grep -nE '\.env\.(lite|voyage|elixir)\.example|docker-compose\.(lite|voyage)\.yml' README.md
```

Expected: empty output.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs(readme): self-host-first rewrite (~70 lines)

Cut 339 lines to ~70. Architecture / data flow / MCP table / API reference
/ MCP config examples / dev quick start move to engram.page/docs/* (already
exist) and to CONTRIBUTING.md. Six shield badges preserved verbatim from
#469."
```

---

## Task 9: Bump `mix.exs` version

**Files:**
- Modify: `mix.exs` (version line)

User-visible change (operator-facing README + compose + env). Per `feedback_no_backend_version_bumps`: one bump per PR, applied at PR-open time. Bumping here so the pre-push hook doesn't reject the push.

- [ ] **Step 1: Read current version**

Run:
```bash
grep -E '^\s*version:' mix.exs
```

Expected: `      version: "0.5.350",`

(If different, use that as the baseline — bump the patch component by 1.)

- [ ] **Step 2: Bump patch from 350 → 351**

Edit `mix.exs`. Change:
```
      version: "0.5.350",
```
to:
```
      version: "0.5.351",
```

- [ ] **Step 3: Verify**

Run:
```bash
grep -E '^\s*version:' mix.exs
```

Expected: `      version: "0.5.351",`

- [ ] **Step 4: Commit**

```bash
git add mix.exs
git commit -m "chore: bump version 0.5.350 → 0.5.351"
```

---

## Task 10: Smoke-test the new self-host path

**Files:** none modified (verification only).

Goal: from a fresh checkout, the README's four commands produce a working `http://localhost:4000`. This is the acceptance gate.

- [ ] **Step 1: Set up a scratch directory outside the worktree**

```bash
SMOKE=/tmp/engram-smoke-$(uname -n)
rm -rf "$SMOKE"
mkdir -p "$SMOKE"
cd "$SMOKE"
```

- [ ] **Step 2: Bring up a fresh checkout of the branch**

```bash
git clone -b docs/readme-self-host-simplification \
  /home/open-claw/documents/code-projects/engram .
```

(Local clone — avoids waiting on a push. The branch must be pushable later; that's the PR step, not this smoke test.)

- [ ] **Step 3: Follow the README literally**

```bash
cp .env.example .env
# Fill in the three secrets at the top
sed -i "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')|" .env
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$(openssl rand -base64 48 | tr -d '\n')|" .env
sed -i "s|^ENCRYPTION_MASTER_KEY=.*|ENCRYPTION_MASTER_KEY=$(openssl rand -base64 32 | tr -d '\n')|" .env
# For plain http on localhost, the .env hint says set these two; do it.
echo "PHX_SCHEME=http" >> .env
echo "PHX_PORT=4000"   >> .env
```

- [ ] **Step 4: Validate the compose file without building**

```bash
docker compose config --quiet
```

Expected: exit code 0.

- [ ] **Step 5: Bring up the stack**

```bash
docker compose up -d --build 2>&1 | tail -20
```

Expected: all five services (`engram`, `postgres`, `qdrant`, `ollama`, `ollama-init`) reach a healthy or completed state within ~3 minutes (image build dominates on first run). No `minio` / `minio-init` containers should appear.

- [ ] **Step 6: Confirm services**

```bash
docker compose ps --format 'table {{.Service}}\t{{.Status}}'
```

Expected: `engram` healthy, `postgres` healthy, `qdrant` running, `ollama` healthy, `ollama-init` exited(0). No `minio`/`minio-init`.

- [ ] **Step 7: Hit the health endpoint**

```bash
curl -sf --max-time 5 http://localhost:4000/api/health
echo
```

Expected: a JSON OK response (exact body depends on health-controller; non-empty + exit 0 = pass).

- [ ] **Step 8: Tear down**

```bash
docker compose down -v
cd /home/open-claw/documents/code-projects/engram/.worktrees/docs-readme-self-host
rm -rf "$SMOKE"
```

- [ ] **Step 9: Repeat Steps 3-7 with the s3 profile**

Same setup but additionally set `STORAGE_BACKEND=s3` in `.env` (uncomment the four `STORAGE_*` lines too) and bring up with the s3 profile:

```bash
docker compose --profile s3 up -d --build
docker compose --profile s3 ps --format 'table {{.Service}}\t{{.Status}}'
```

Expected: all five default services PLUS `minio` healthy and `minio-init` exited(0). `curl http://localhost:4000/api/health` returns OK.

- [ ] **Step 10: Tear down s3 stack**

```bash
docker compose --profile s3 down -v
cd /home/open-claw/documents/code-projects/engram/.worktrees/docs-readme-self-host
rm -rf "$SMOKE"
```

- [ ] **Step 11: No commit (verification only).**

If Steps 1-10 all passed, the acceptance gate is met. If any step failed, file the failure as a task amendment and halt before proceeding to Task 11.

---

## Task 11: File the sibling marketing-docs issue

**Files:** none modified locally (GitHub-side issue creation).

The README links to `https://engram.page/docs/self-host/environment-variables/#embeddings` and `#storage`. Those anchors need to exist in `engram-app/engram-marketing` for the links to resolve. This task creates the tracking issue; a separate PR over there ships the changes.

- [ ] **Step 1: Confirm the anchors don't yet exist**

```bash
grep -nE '(^#|^##|^###)\s+(Embeddings|Storage|S3)' \
  /home/open-claw/documents/code-projects/engram-marketing/src/content/docs/docs/self-host/environment-variables.mdx
```

Expected: empty or only unrelated headings. If `Embeddings` or `Storage` already exist with the right slugs (`#embeddings`, `#storage`), still file the issue but note in the body that they exist and only need a content check.

- [ ] **Step 2: Open the tracking issue on engram-marketing**

```bash
gh issue create \
  --repo engram-app/engram-marketing \
  --title "self-host docs: add #embeddings + #storage anchors for new README deep-links" \
  --body "$(cat <<'EOF'
The simplified engram README (engram-app/Engram PR for branch
`docs/readme-self-host-simplification`) links to two deep anchors that need
to exist on the docs site:

- `engram.page/docs/self-host/environment-variables/#embeddings`
- `engram.page/docs/self-host/environment-variables/#storage`

## What each anchor should cover

**#embeddings** — How to switch from Ollama (default) to Voyage AI. The env
block to set, threshold guidance ("paid; better quality; needs outbound
HTTP to api.voyageai.com"), and where to get an API key. Mirror the
commented block in the new `.env.example`.

**#storage** — How to switch from Postgres bytea attachments (default) to
MinIO/S3. The env block to set, the threshold guidance from the README
(\"largest file > ~50 MB, or > ~10 GB total, or want existing S3\"), the
\`docker compose --profile s3 up -d\` invocation, and a note about backup
implications (bytea bloats DB dumps; MinIO needs its own backup).

## Why now

The new README ships with deep links; if this docs PR doesn't land
same-day, those links 404 briefly. Same-day landing is the goal.
EOF
)"
```

- [ ] **Step 2: Confirm issue created**

The `gh issue create` output prints the issue URL. Copy it into the PR description for this branch's PR so reviewers can see the linkage.

- [ ] **Step 3: No commit (issue is GitHub-side state).**

---

## Task 12: Open the PR

**Files:** none modified.

- [ ] **Step 1: Push the branch**

```bash
cd /home/open-claw/documents/code-projects/engram/.worktrees/docs-readme-self-host
git push -u origin docs/readme-self-host-simplification
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create \
  --title "docs(self-host): simplify README + collapse compose/env presets" \
  --body "$(cat <<'EOF'
## Summary

- README: 339 → ~70 lines, self-host first, educational content linked to existing `engram.page/docs/*` pages
- Compose presets: 3 → 1 (`docker-compose.yml`) with MinIO behind `--profile s3`
- Env examples: 3 → 1 (`.env.example`) with Voyage + MinIO as commented switches with docs links
- Internal `.env.deploy` moved out of repo root to `scripts/deploy.env`
- `CONTRIBUTING.md` now owns dev quick start + testing (was looping back at README)
- Six shield badges from PR #469 preserved verbatim

## Spec

`docs/superpowers/specs/2026-06-05-readme-self-host-simplification-design.md`

## Plan

`docs/superpowers/plans/2026-06-05-readme-self-host-simplification.md`

## Sibling docs PR

Marketing-side anchors (`#embeddings`, `#storage`) tracked in
engram-marketing#TODO (replace with URL from Task 11). Goal is same-day
landing so README deep-links resolve on merge.

## Test plan

- [x] `docker compose config` validates both default + `--profile s3`
- [x] Fresh `git clone` + 4-command README path brings up healthy
      `http://localhost:4000/api/health`
- [x] `docker compose --profile s3 up -d` brings up MinIO + creates bucket
- [x] No tracked file references the deleted compose or env files
      (`git grep` verified per task)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Paste the marketing-docs issue URL into the PR description**

Open the PR in the browser (the URL is in the `gh pr create` output), edit the description, replace `engram-marketing#TODO` with the URL from Task 11 Step 2.

- [ ] **Step 4: Wait for CI**

Run:
```bash
gh pr checks --watch
```

Expected: all checks green. If any check fails, halt and triage.

---

## Acceptance criteria recap

From the spec:

1. ✅ `README.md` ≤ ~70 lines, structured as in D3 (Task 8)
2. ✅ `docker-compose.lite.yml` and `docker-compose.voyage.yml` deleted (Task 5)
3. ✅ `docker-compose.yml` has `profiles: [s3]` on the `minio` service (Task 4)
4. ✅ Root has exactly one tracked `.env.*.example` (the new `.env.example`); `.env.deploy` moved (Tasks 1-3, 6)
5. ✅ `CONTRIBUTING.md` owns the dev-setup content (Task 7)
6. ✅ Fresh `git clone` + four-command path brings up working `http://localhost:4000` (Task 10)
7. ✅ CI green (Task 12)
8. ✅ Sibling marketing-docs issue filed (Task 11)

# README + Self-Host Onramp Simplification — Design

**Date:** 2026-06-05
**Status:** Approved (brainstorming complete; ready for plan)
**Owner:** todd

## Problem

A friend tried to set up the self-hosted version of Engram and bounced off the
complexity. The repo root pushes nine choices onto a first-time self-hoster:

- Three `docker-compose.*.yml` self-host presets (`default` / `lite` / `voyage`)
  side-by-side with five non-self-host compose files (`dev` / `elixir` / `ci` /
  `ci-database` / `ci-local` / `parity`).
- Three tracked `.env.*.example` files (`.env.example`, `.env.lite.example`,
  `.env.voyage.example`) plus a `.env.elixir.example` and a `.env.deploy`.
- A 339-line `README.md` that mixes three audiences — self-hoster, API/MCP
  consumer, contributor — into one wall of text. The self-host section
  (~25 lines) is buried at line 79 between an ASCII architecture diagram
  and a 100-line "Development Quick Start" aimed at people hacking on
  Engram itself.

The marketing docs site at `engram.page/docs/self-host/` already mirrors most
of the README's educational content — quickstart, env-var reference,
encryption, backup/restore, upgrade, troubleshooting, architecture — and
the same is true for `/docs/api/`, `/docs/mcp/`. The README duplication is a
drift risk plus a noise tax on every reader.

## Goal

Make the self-host onramp obvious. README answers exactly one question:
"how do I get this running?" Education and reference move to the docs
site, which is already structured for them.

Concretely:

- ONE compose path for self-host with ONE opt-in toggle (S3/MinIO via Compose
  profile). Voyage AI becomes a `.env` switch, not a separate file.
- ONE tracked `.env.*.example` (the new `.env.example`) covering both default
  self-host and the dev-contributor case.
- README ≤ ~70 lines: tagline → run command → opt-in toggles → docs link
  table → license/security/contributing.

## Decisions (locked during brainstorming)

### D1. Compose presets: collapse three → two, voyage → doc-only

| Before | After |
|---|---|
| `docker-compose.yml` (default: Ollama + MinIO) | `docker-compose.yml` (default: Ollama + Postgres bytea) |
| `docker-compose.lite.yml` (Ollama + Postgres bytea) | DELETED — becomes the default |
| `docker-compose.voyage.yml` (Voyage + MinIO) | DELETED — Voyage is an `.env` switch |
| n/a | `--profile s3` opt-in inside `docker-compose.yml` for MinIO |

The five non-self-host compose files (`docker-compose.dev.yml`,
`docker-compose.elixir.yml`, `docker-compose.ci*.yml`,
`docker-compose.parity.yml`) are out of scope for this pass — they serve
contributors and CI, not self-hosters, and CI workflows reference them by
filename.

#### Why "lite" becomes the default

Postgres `bytea` attachment storage avoids the MinIO container entirely:
fewer credentials to generate (no MinIO root password), fewer services to
fail on first boot, smaller mental model. Postgres TOAST hard-caps a single
`bytea` value at 1 GB, but the practical limit is operator tolerance for
backup size — fine for the typical self-host vault (a few hundred MB of
attachments).

#### How MinIO opts in

Compose Profiles (Compose v2.3+):

```yaml
services:
  minio:
    profiles: [s3]
    # ...
```

```bash
# Default (no MinIO, bytea attachments):
docker compose up -d

# With MinIO for large attachments:
docker compose --profile s3 up -d
```

The compose profile (which container exists) and `STORAGE_BACKEND` env
(which code path the app uses) line up 1:1. Setting `STORAGE_BACKEND=s3`
without `--profile s3` fails loudly at boot (cannot reach `minio:9000`),
which is the correct failure mode.

#### MinIO threshold guidance

Goes into both `.env.example` comments and
`docs/self-host/environment-variables.mdx`:

> **Use the default (`STORAGE_BACKEND=database`) when** total vault
> attachments < ~5 GB and largest single attachment < ~50 MB.
> **Switch to MinIO/S3 (`--profile s3`) when** you store videos, large
> PDFs, or expect > 10 GB attachments — keeps Postgres dumps small.

### D2. Env files: collapse five → one tracked example

| Before | After |
|---|---|
| `.env.example` (6,674 bytes) | **Rewritten** ~50 lines: required at top, Voyage + MinIO as commented blocks with doc links |
| `.env.lite.example` | DELETED |
| `.env.voyage.example` | DELETED |
| `.env.elixir.example` | DELETED — dev contributors copy the same `.env.example`; extra dev-only vars (Clerk dev keys, Paddle sandbox) are documented in `CONTRIBUTING.md` |
| `.env.deploy` | MOVE → `scripts/deploy.env` (internal FastRaid deploy, not for self-hosters) |

Final root has one tracked `.env.example`. The six committed but untracked
env-state files (`.env`, `.env.dev`, `.env.local`, `.env.local-saasdev`,
`.env.local-selfhost`, `.env.elixir`) are not in scope — they're already
gitignored (verified: `git ls-files | grep '^\.env'` returns only the five
above).

Skeleton of the new `.env.example`:

```env
# ─────────────────────────────────────────────
# Engram — required for every install
# ─────────────────────────────────────────────
DATABASE_URL=postgresql://engram:engram@db:5432/engram
SECRET_KEY_BASE=          # openssl rand -base64 48
JWT_SECRET=               # openssl rand -base64 48
ENCRYPTION_MASTER_KEY=    # openssl rand -base64 32  — BACK THIS UP
PHX_HOST=localhost        # set to your domain in production

# ─────────────────────────────────────────────
# Embedding backend (default: Ollama, no API key)
# ─────────────────────────────────────────────
EMBED_BACKEND=ollama
EMBED_MODEL=nomic-embed-text
EMBED_DIMS=768

# To use Voyage AI instead (better quality, paid):
#   EMBED_BACKEND=voyage
#   EMBED_MODEL=voyage-4-large
#   EMBED_DIMS=1024
#   VOYAGE_API_KEY=...
# Docs: https://engram.page/docs/self-host/environment-variables/#embeddings

# ─────────────────────────────────────────────
# Attachment storage (default: Postgres, fine for most vaults)
# ─────────────────────────────────────────────
STORAGE_BACKEND=database

# To use S3/MinIO instead (large vaults — see threshold guidance):
#   STORAGE_BACKEND=s3
#   S3_ENDPOINT=http://minio:9000
#   S3_BUCKET=engram-attachments
#   S3_ACCESS_KEY_ID=...
#   S3_SECRET_ACCESS_KEY=...
# Also start the MinIO container: docker compose --profile s3 up -d
# Docs: https://engram.page/docs/self-host/environment-variables/#storage
```

The full env-var catalogue (every optional knob — Clerk, Paddle, Sentry,
Voyage tuning, OAuth, etc.) lives in
`docs/self-host/environment-variables.mdx` on the marketing site.

### D3. README structure: ≤ ~70 lines, self-host first

Cuts (and where they go):

| Cut from README | Moves to |
|---|---|
| ASCII architecture diagram (lines 11-33) | `engram.page/docs/self-host/architecture/` (already exists) |
| "Data Flow" indexing + search blocks (lines 35-54) | same |
| MCP tools table (lines 56-68) | `engram.page/docs/mcp/` (already exists) |
| "Architecture" bullets (lines 70-77) | `engram.page/docs/self-host/architecture/` |
| "Development Quick Start" 7 steps (lines 117-216) | `CONTRIBUTING.md` (new "Local development" section) |
| "MCP Configuration" JSON examples (lines 218-250) | `engram.page/docs/mcp/manual-config/` (already exists) |
| "API Reference" tables (lines 252-304) | `engram.page/docs/api/` (already exists) |
| "Testing" section (lines 306-316) | `CONTRIBUTING.md` |
| "Production Deployment" paragraph (lines 318-320) | DELETED — no operator signal |

Keeps (preserved verbatim or condensed):

- Six shield badges (added 2026-06-05 in PR #469) — preserved as-is
- Tagline + one-paragraph product description
- Self-host quickstart (now ~7 lines, single command path)
- Two-line toggles for Voyage and S3/MinIO with doc links
- Doc-link table to the marketing site
- License (PolyForm SB 1.0.0 + Commercial) — legal needs README presence
- Security section (link to `SECURITY.md`)
- Contributing one-liner pointing at `CONTRIBUTING.md`

Target README (skeleton, final wording polished during impl):

```markdown
# Engram

[shields × 6 — verbatim from current main]

Your notes are your AI's memory.

The AI memory layer where your notes are the storage — markdown you and
your AI assistants both read and write to via [MCP](https://modelcontextprotocol.io).
Built with Elixir/Phoenix. Pairs with the [Engram Obsidian Sync](https://github.com/engram-app/Engram-obsidian)
plugin for real-time bidirectional sync.

## Self-Host (Docker Compose)

    git clone https://github.com/engram-app/engram.git
    cd engram
    cp .env.example .env       # then fill in the 3 secrets at the top
    docker compose up -d

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
| Quickstart           | https://engram.page/docs/self-host/quickstart/ |
| Environment vars     | https://engram.page/docs/self-host/environment-variables/ |
| Encryption & keys    | https://engram.page/docs/self-host/encryption/ |
| Backup & restore     | https://engram.page/docs/self-host/backup-restore/ |
| Upgrades             | https://engram.page/docs/self-host/upgrade/ |
| Troubleshooting      | https://engram.page/docs/self-host/troubleshooting/ |
| Architecture         | https://engram.page/docs/self-host/architecture/ |
| MCP setup            | https://engram.page/docs/mcp/ |
| HTTP API             | https://engram.page/docs/api/ |

## Contributing

Local dev setup, tests, PR rules: see [CONTRIBUTING.md](./CONTRIBUTING.md).

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

See [SECURITY.md](./SECURITY.md) for vulnerability disclosure.

Copyright (c) 2026 Rasbandit Software Solutions LLC d/b/a Engram.
```

### D4. CONTRIBUTING.md absorbs dev quick start

Currently `CONTRIBUTING.md:54` says *"See [README.md] Quick Start for local
environment setup"* — backwards. The fix:

- Add a "Local development" section to `CONTRIBUTING.md` with the seven
  steps from the old README (prereqs, `mix deps.get`, `.env`, `mix
  phx.server`, register/login, push note, search). Trim curl examples
  to one or two illustrative ones; full API contract is on the docs site.
- Add a "Testing" subsection mirroring old README "Testing".
- Add MCP-server config snippet (Claude Code / Claude Desktop) only if
  the contributor needs it for local MCP work; otherwise leave to docs
  site.
- Remove the line that points back at README.

### D5. Marketing doc gaps to fill (out of scope for this PR; spawn issues)

Most marketing pages already exist. Two pages should grow anchors so the
new README's `#embeddings` and `#storage` deep-links resolve:

- `docs/self-host/environment-variables.mdx` — add `#embeddings` and
  `#storage` headings with the Voyage env block + MinIO threshold
  guidance + `STORAGE_BACKEND` matrix.

That single marketing-docs PR is a sibling of this README PR; spec writer
should file the issue but not block on it.

## Out of scope (explicit)

- The five non-self-host compose files (`dev`, `elixir`, `ci*`, `parity`)
  are untouched. They serve contributors and CI.
- The six untracked `.env.*` working-state files in root are untouched —
  they're already gitignored.
- `docker-compose.yml` internal structure is **not** being redesigned;
  just adopting the `profiles: [s3]` toggle for MinIO and removing the
  separate `.lite.yml` / `.voyage.yml` files. Voyage-AI app-side env
  switching already works (see `lib/engram/embedding/`).
- No app-code or behavior changes. README + compose + env + CONTRIBUTING
  only.
- Marketing-docs additions (env-var anchors, S3 setup deep-dive) ship in a
  separate PR on `engram-app/engram-marketing`.

## Acceptance criteria

1. `README.md` ≤ ~70 lines, structured as in D3.
2. `docker-compose.lite.yml` and `docker-compose.voyage.yml` deleted.
3. `docker-compose.yml` has `profiles: [s3]` on the `minio` service and
   matches the new `.env.example` default (Ollama + Postgres bytea).
4. Root has exactly one tracked `.env.*.example` (the new `.env.example`).
   `.env.lite.example`, `.env.voyage.example`, `.env.elixir.example`
   deleted. `.env.deploy` moved to `scripts/deploy.env` with any
   referencing scripts updated.
5. `CONTRIBUTING.md` owns the dev-setup content; README contains a
   one-line pointer.
6. A fresh `git clone` + the README's four-command path brings up a
   working `http://localhost:4000` with migrations run, no further
   reading required. Manually verified on a fresh checkout.
7. CI green. (No app-code changes, so CI delta should be limited to
   workflow files that reference the deleted compose filenames — audit
   `.github/workflows/` during impl.)
8. Sibling marketing-docs issue filed on `engram-app/engram-marketing`
   to land the env-var anchors (`#embeddings`, `#storage`).

## Risks

- **CI workflows reference deleted compose filenames.** Impl must grep
  `.github/workflows/` for `docker-compose.lite.yml` /
  `docker-compose.voyage.yml` / `.env.lite.example` / `.env.voyage.example`
  before deleting and update or delete-with-them.
- **External users with bookmarked old `.env.*.example` filenames.**
  Mitigation: PR description calls out the rename; CHANGELOG entry
  (`mix.exs` version bump per `feedback_no_backend_version_bumps`).
- **Marketing-docs deep-links don't exist yet.** Mitigation: file the
  sibling docs issue at PR-open time; if the docs PR lands first, README
  links are live on merge; otherwise links 404 briefly until the docs PR
  ships. Acceptable for a few hours; not acceptable for days. Owner is
  responsible for landing both on the same day.
- **`.env.deploy` consumers.** `bin/deploy-fastraid` and any other
  scripts may source `.env.deploy` from repo root. Impl grep for
  `\.env\.deploy` across the repo before moving.

## Implementation order (one concern per step — per workspace style)

1. New `.env.example` written + old three deleted + `.env.elixir.example`
   removed.
2. `docker-compose.yml` rewritten to be the (former) lite shape + `s3`
   profile added for MinIO. Delete `docker-compose.lite.yml` +
   `docker-compose.voyage.yml`.
3. CI workflow audit + fix any references to deleted files.
4. `CONTRIBUTING.md` absorbs dev quick start + testing.
5. `README.md` rewritten to the D3 shape.
6. `.env.deploy` moved to `scripts/deploy.env`; deploy scripts updated.
7. Manual smoke test: fresh `git clone` → README's four commands → load
   `http://localhost:4000`.
8. Sibling marketing-docs issue filed.

Per workspace rules, the entire change ships as a single PR
(`feedback_single_pr_all_changes`). Steps above are commit boundaries
inside the one branch, not separate PRs.

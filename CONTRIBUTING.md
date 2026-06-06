# Contributing to Engram

Thanks for your interest. Engram is a small, focused project. Bug reports,
feature requests, and pull requests are all welcome.

## Reporting bugs

Open an issue on GitHub with:

- What you expected to happen
- What actually happened
- Steps to reproduce (commands, payloads, etc.)
- Engram version (`mix.exs` `version:`) and deployment mode (SaaS / self-hosted)
- Relevant logs (sanitize secrets first)

## Proposing changes

For non-trivial changes, open an issue first to discuss the approach before
spending time on a PR. For small bug fixes, a direct PR is fine.

## Contributor License Agreement (CLA)

Engram is dual-licensed: source-available under the
[PolyForm Small Business License 1.0.0](LICENSE) for the public, and under a
commercial license for organizations above the Small Business threshold (see
[LICENSE-COMMERCIAL.md](LICENSE-COMMERCIAL.md)).

To keep this model viable, every contributor must agree to the project's
**Contributor License Agreement** — see [.github/CLA.md](.github/CLA.md) — the
first time they open a pull request.

The CLA does **not** transfer copyright. You keep ownership of your
contribution. You grant Rasbandit Software Solutions LLC d/b/a Engram a broad
license — including the right to relicense your contribution under the
commercial license — so the dual-license model works.

**How to sign (interim manual flow):** Read [.github/CLA.md](.github/CLA.md),
then post the following line as a comment on your pull request, verbatim:

> I have read the Engram Contributor License Agreement v1.0 and I hereby sign
> the CLA.

A maintainer will record your signature and proceed with review.

> **TODO (deferred):** automated CLA enforcement tooling will be wired up
> when external contributions become regular. The CLA Assistant Lite
> GitHub Action was archived upstream in March 2026, and the hosted
> `cla-assistant.io` service has been on maintenance-only mode since late
> 2023. Choosing tooling against a moving landscape was deferred until a
> real signal exists.

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

## Pull request expectations

- One concern per PR. Split refactors out from feature changes.
- All four lint checks pass locally: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`,
  `mix sobelow --exit low`. Dialyzer runs in CI.
- Tests added for new behavior. See `docs/context/testing-strategy.md`.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, ...).
- `mix.exs` `version:` bumped if the change is user-visible (pre-push hook
  enforces this).

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

## Development setup

See [README.md](README.md) "Quick Start" for local environment setup, and
[CLAUDE.md](CLAUDE.md) for architecture and workflow details.

## Pull request expectations

- One concern per PR. Split refactors out from feature changes.
- All four lint checks pass locally: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`,
  `mix sobelow --exit low`. Dialyzer runs in CI.
- Tests added for new behavior. See `docs/context/testing-strategy.md`.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `chore:`, ...).
- `mix.exs` `version:` bumped if the change is user-visible (pre-push hook
  enforces this).

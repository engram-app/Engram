# syntax=docker/dockerfile:1
# check=skip=SecretsUsedInArgOrEnv
#
# `check=skip=SecretsUsedInArgOrEnv`: BuildKit's lint flags any ARG/ENV whose
# name contains KEY/TOKEN/SECRET. Our `VITE_CF_BEACON_TOKEN` and
# `VITE_POSTHOG_KEY` trip this heuristic but are NOT secrets — Vite bakes
# `import.meta.env.VITE_*` into the JS bundle that ships to every browser.
# Both are public per-site identifiers (CF beacon: rate-limited per-site;
# PostHog: write-only event ingest per project). They cannot be hidden by
# any build-time mechanism. The check is a true false-positive; skipping
# the rule for the whole Dockerfile keeps the build clean without changing
# real risk posture. Real secrets in this Dockerfile use `RUN
# --mount=type=secret` (see `sentry_auth_token` usage in the frontend stage).
#
# Multi-stage build: compile release in builder, run in minimal image
# cache-bust: 2026-04-18-encryption-auto-provision
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.3.4.14
ARG DEBIAN_VERSION=bookworm-20260623-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"
# The image the app compiles on top of: toolchain + fetched AND compiled prod
# deps. Default = the `deps` stage below, so a plain `docker build` (self-host,
# local) is self-contained. CI passes a prebuilt `${LOCAL_REGISTRY}/engram-deps:
# <hash of mix.lock + Cargo.lock + this file + deps' config>` instead, so no runner
# recompiles 69 deps (~210s) unless the lockfile moved.
ARG DEPS_IMAGE=deps

# ─── Frontend build ──────────────────────────────────────────────────────
FROM oven/bun:1.3 AS frontend

# Build-args propagated from CI for Sentry wiring. All optional; the
# Sentry React SDK + Vite plugin no-op when their env vars are unset,
# so a build without these (local `docker build`, self-host) still
# works.
#   VITE_SENTRY_DSN — baked into the bundle; turns on Sentry.init in
#       the browser.
#   VITE_GIT_SHA    — release tag used by Sentry to symbolicate stack
#       traces against the right source-map upload.
# The image build deliberately does NOT take SENTRY_ORG / SENTRY_PROJECT /
# SENTRY_AUTH_TOKEN: without an auth token @sentry/vite-plugin is disabled,
# so this image uploads no source maps and ships none. Source-map upload is
# the SaaS bundle's job (verify.yml + frontend-promote.yml).
ARG VITE_SENTRY_DSN
ARG VITE_GIT_SHA
# Cloudflare Web Analytics beacon — public per-site identifier.
# Build-arg so self-host bundles don't ship the SaaS-side token.
ARG VITE_CF_BEACON_TOKEN
# PostHog — public project token (write-only event ingest, per-project).
# Same self-host-shouldn't-emit-to-SaaS rationale as the CF beacon.
ARG VITE_POSTHOG_KEY
ARG VITE_POSTHOG_HOST
ENV VITE_SENTRY_DSN=${VITE_SENTRY_DSN} \
    VITE_GIT_SHA=${VITE_GIT_SHA} \
    VITE_CF_BEACON_TOKEN=${VITE_CF_BEACON_TOKEN} \
    VITE_POSTHOG_KEY=${VITE_POSTHOG_KEY} \
    VITE_POSTHOG_HOST=${VITE_POSTHOG_HOST}

WORKDIR /frontend
COPY frontend/package.json frontend/bun.lock ./
# `patchedDependencies` in package.json: bun install fails if the patch files are absent.
COPY frontend/patches ./patches
# Bun global package cache survives across builds on self-hosted runners.
RUN --mount=type=cache,target=/root/.bun/install/cache,id=bun-cache \
    bun install --frozen-lockfile
COPY frontend/ ./
# `--mount=type=secret` is the leak-safe path for SENTRY_AUTH_TOKEN —
# exposed as a tmpfs file readable only inside this RUN, never
# persisted in image layers or `docker history`. The Vite plugin
# self-disables if the token is missing, so this same `bun run build`
# line is the no-op branch for builds without the secret.
RUN --mount=type=secret,id=sentry_auth_token,env=SENTRY_AUTH_TOKEN \
    bun run build:selfhost

# ─── Elixir toolchain + compiled deps ─────────────────────────────────────
FROM ${BUILDER_IMAGE} AS deps

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -y && apt-get install -y build-essential git

# Rust for the in-house NIFs (native/), BUILDER STAGE ONLY: the release ships
# the compiled .so and the runner image has no Rust. Copied from the official
# image pinned by DIGEST (same bookworm base, so the same glibc) rather than
# piping an installer into a shell. Version matches
# native/rust-toolchain.toml (the Cargo workspace's pin); keep the two in
# sync.
COPY --from=rust:1.94.1-slim-bookworm@sha256:cf9dd0ec73e75f827fe59123fff9dc65af1a1c8363c3c31ee8d7f8ad0b6a5fb2 /usr/local/rustup /usr/local/rustup
COPY --from=rust:1.94.1-slim-bookworm@sha256:cf9dd0ec73e75f827fe59123fff9dc65af1a1c8363c3c31ee8d7f8ad0b6a5fb2 /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH

WORKDIR /app

ENV MIX_ENV="prod"
# Optional LAN Hex pull-through mirror (e.g. http://10.0.20.214:8090). Empty =
# upstream repo.hex.pm, so non-LAN builders are unaffected. Both `mix deps.get`
# calls below honor it. Hex still verifies package signatures against hex.pm's
# key, so a caching mirror is safe (we never set unsafe_registry).
ARG HEX_MIRROR=""
# Fall back to upstream when the arg arrives EMPTY, not merely unset.
# `ci/compose.yml` passes `HEX_MIRROR: ${HEX_MIRROR:-}` and its comment says
# "empty for local dev = upstream" — but `ENV HEX_MIRROR=` SETS the variable to
# an empty string rather than leaving it unset, and mix then parses "" as a URI:
#
#   ** (CaseClauseError) no case clause matching: :badpath
#       (mix) lib/mix/tasks/local.hex.ex:72: Mix.Tasks.Local.Hex.run_install/2
#
# So `docker compose -f ci/compose.yml build` — the documented way to bring the
# CI stack up locally — could not work off the LAN, while CI stayed green
# because it always passes a real mirror. Defaulted here rather than in compose
# so every caller is covered.
ENV HEX_MIRROR=${HEX_MIRROR:-https://repo.hex.pm}
# Persist hex + rebar package caches across builds (self-hosted runner disk).
# Without these mounts, mix.exs invalidation re-downloads every hex tarball.
RUN --mount=type=cache,target=/root/.hex,id=mix-hex \
    --mount=type=cache,target=/root/.cache/rebar3,id=mix-rebar \
    mix local.hex --force && mix local.rebar --force

# deps/ and _build/ live in LAYERS, not cache mounts. The old mounts were
# per-daemon (useless across the runner pool), pruned to 2GB after e2e jobs,
# and absent from the final RUN, so every build compiled all deps twice and
# kept neither. Only download caches (hex, rebar) stay as mounts.
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/root/.hex,id=mix-hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,id=mix-rebar,sharing=locked \
    mix deps.get --only $MIX_ENV

# config.exs/prod.exs carry deps' compile-time config, so they are inputs of
# this stage (and of the CI deps-image hash). runtime.exs is not.
RUN mkdir -p config
COPY config/config.exs config/prod.exs config/
RUN --mount=type=cache,target=/root/.hex,id=mix-hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,id=mix-rebar,sharing=locked \
    mix deps.compile

# Warm native/target with the NIF's crates.io deps (~1 min of the old build).
# The builder stage re-COPYs native/ and Rustler's cargo build reuses every
# unchanged crate, so this layer only has to be roughly current, never exact.
COPY native native
RUN --mount=type=cache,target=/usr/local/cargo/registry,id=cargo-registry,sharing=locked \
    cd native && cargo build --release -p engram_native

# ─── Elixir app build ────────────────────────────────────────────────────
FROM ${DEPS_IMAGE} AS builder

# Real project files over whatever the deps image was built from (mix.exs's
# version moves every release; the deps image is keyed on mix.lock only).
COPY mix.exs mix.lock ./
COPY config config
COPY lib lib
COPY native native
COPY priv priv
# Engram.Notes.KeyAliases reads the generated frontmatter key catalogs and the
# named-field list at compile time; they live with the web app's catalogs (one
# source for both).
COPY frontend/src/i18n/locale/keys frontend/src/i18n/locale/keys
COPY frontend/src/i18n/frontmatter-key-fields.json frontend/src/i18n/frontmatter-key-fields.json
# rel/ holds env.sh.eex, whose ECS_ENABLE_CLUSTER gate exports
# RELEASE_DISTRIBUTION=name + RELEASE_NODE=engram@<ip> for BEAM clustering
# (engram-app/Engram#710). Without this COPY, `mix release` below never sees
# the template and emits the DEFAULT env.sh (short-name `sname` mode) — so the
# clustering env var lands on a release that can't read it and nodes never
# connect (peers=0). Must be COPY'd before `mix release`.
COPY rel rel
# `deps.get` is a no-op when the deps image matches mix.lock and fetches the
# delta when it does not (a stale/foreign DEPS_IMAGE can never ship old deps).
# `--force` recompiles only this app; deps are already compiled in the layer.
# No _build cache mount: a shared _build mount is what produced stale beams in
# CI before, so _build stays in the layer.
RUN --mount=type=cache,target=/root/.hex,id=mix-hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,id=mix-rebar,sharing=locked \
    --mount=type=cache,target=/usr/local/cargo/registry,id=cargo-registry,sharing=locked \
    mix deps.get --only $MIX_ENV && \
    mix compile --force

# Frontend assets are needed by `mix release` only, so a frontend-only change
# starts here instead of recompiling the Elixir app.
COPY --from=frontend /priv/static/app priv/static/app
RUN mix release && \
    sh -c 'grep -q ECS_ENABLE_CLUSTER /app/_build/prod/rel/engram/releases/*/env.sh || { echo "FATAL: clustering gate (ECS_ENABLE_CLUSTER) missing from release env.sh — was rel/ copied before mix release? See engram-app/Engram#710" >&2; exit 1; }' && \
    cp -r /app/_build/prod/rel/engram /app/_release

# ─── Runner ───────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE}

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -y && apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl

# Set locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN chown nobody /app

COPY --from=builder --chown=nobody:root /app/_release ./
COPY --chown=nobody:root --chmod=0755 entrypoint.sh /entrypoint.sh

USER nobody

EXPOSE 4000

ENV PHX_SERVER=true

# The commit this image was built from, baked in at build time so the image
# knows what it is in EVERY environment. Previously RELEASE_SHA was injected
# per-environment from Terraform (`var.engram_release_sha`), which prod set
# and staging-fastraid did not — so there was no way to tell what code
# staging was running short of `docker inspect` on the host. That blind spot
# is how a broken staging deploy chain went unnoticed for weeks: /api/health
# reports Application.spec(:engram, :vsn), which release-please keeps sticky
# between cuts, so it cannot change on a non-release deploy.
#
# Baking it here also removes the lockstep requirement between the image and
# a TF variable — the value can no longer drift from the bytes it describes.
# Empty default keeps local `docker build` and self-host builds working; the
# health endpoint and Sentry both treat "" as unset.
ARG RELEASE_SHA=""
ENV RELEASE_SHA=${RELEASE_SHA}

# T3.0.3 — refuse to write erl_crash.dump on BEAM crash. The dump would
# include plaintext DEKs (ETS) + master key (LocalKeyProvider state) from
# process heap. Unraid templates also set this; this line is the defense-
# in-depth default so a template that drifts can't open the leak.
ENV ERL_CRASH_DUMP_BYTES=0

# Migrate-then-start via /entrypoint.sh. CMD is JSON/exec form so signals
# (SIGTERM on graceful shutdown) reach BEAM directly instead of being
# absorbed by an intermediate shell.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/app/bin/engram", "start"]

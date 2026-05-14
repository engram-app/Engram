# syntax=docker/dockerfile:1
# Multi-stage build: compile release in builder, run in minimal image
# cache-bust: 2026-04-18-encryption-auto-provision
ARG ELIXIR_VERSION=1.17.3
ARG OTP_VERSION=27.1.2
ARG DEBIAN_VERSION=bookworm-20241202-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ─── Frontend build ──────────────────────────────────────────────────────
FROM oven/bun:1.3 AS frontend

WORKDIR /frontend
COPY frontend/package.json frontend/bun.lock ./
# Bun global package cache survives across builds on self-hosted runners.
RUN --mount=type=cache,target=/root/.bun/install/cache,id=bun-cache \
    bun install --frozen-lockfile
COPY frontend/ ./
RUN bun run build

# ─── Elixir build ────────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update -y && apt-get install -y build-essential git

WORKDIR /app

ENV MIX_ENV="prod"
# Persist hex + rebar package caches across builds (self-hosted runner disk).
# Without these mounts, mix.exs invalidation re-downloads every hex tarball.
RUN --mount=type=cache,target=/root/.hex,id=mix-hex \
    --mount=type=cache,target=/root/.cache/rebar3,id=mix-rebar \
    mix local.hex --force && mix local.rebar --force

# Fetch deps — cache mount means only changed deps are re-downloaded.
# sharing=locked: concurrent builds (push + plugin dispatch) serialize on
# this mount inside buildkit instead of corrupting shared state. Default
# sharing=shared raced and aborted with "graceful_stop" mid-compile.
COPY mix.exs mix.lock ./
RUN --mount=type=cache,target=/app/deps,id=mix-deps,sharing=locked \
    --mount=type=cache,target=/root/.hex,id=mix-hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,id=mix-rebar,sharing=locked \
    mix deps.get --only $MIX_ENV

# Compile deps — cache mount preserves compiled artifacts between builds.
# sharing=locked on the large write-heavy mounts (mix-deps, mix-build) —
# see comment above.
RUN mkdir -p config
COPY config/config.exs config/runtime.exs config/prod.exs config/
RUN --mount=type=cache,target=/app/deps,id=mix-deps,sharing=locked \
    --mount=type=cache,target=/app/_build,id=mix-build,sharing=locked \
    --mount=type=cache,target=/root/.hex,id=mix-hex,sharing=locked \
    --mount=type=cache,target=/root/.cache/rebar3,id=mix-rebar,sharing=locked \
    mix deps.compile

# Compile app code — frontend assets not needed for compilation,
# only for the release. Keeping them separate means frontend-only
# changes don't invalidate the Elixir compile layer.
# (runtime.exs already copied above — not re-copied here.)
COPY lib lib
COPY priv priv
COPY --from=frontend /priv/static/app priv/static/app
# Compile and release in one RUN, no _build cache mount. Splitting the
# two steps with a shared _build cache produced stale beams in CI —
# `mix compile --force` ran but `mix release` in the next RUN still
# saw old beam files. Single-step build is correct; the extra minute
# of compile time is worth the guarantee that the release matches the
# current source.
RUN --mount=type=cache,target=/app/deps,id=mix-deps,sharing=locked \
    mix compile --force && \
    mix release && \
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

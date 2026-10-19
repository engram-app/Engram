# Mix builder for CI: the release builder image plus a C toolchain, Rust and
# hex/rebar. Every CI job that runs `mix` runs it in this image, bind-mounted
# at /app, so the _build that prebuild-mix caches is valid in every consumer.
# See docs/context/ci-mix-compile-cache-runner-path.md.
ARG BASE
FROM ${BASE}
ARG HEX_MIRROR=""
ENV HEX_MIRROR=${HEX_MIRROR}
RUN apt-get update -y && apt-get install -y --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*
# Rust for native/ (in-house NIFs): same digest-pinned image as the release
# Dockerfile's builder stage.
COPY --from=rust:1.94.1-slim-bookworm@sha256:cf9dd0ec73e75f827fe59123fff9dc65af1a1c8363c3c31ee8d7f8ad0b6a5fb2 /usr/local/rustup /usr/local/rustup
COPY --from=rust:1.94.1-slim-bookworm@sha256:cf9dd0ec73e75f827fe59123fff9dc65af1a1c8363c3c31ee8d7f8ad0b6a5fb2 /usr/local/cargo /usr/local/cargo
ENV RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo PATH=/usr/local/cargo/bin:$PATH
RUN mix local.hex --force && mix local.rebar --force

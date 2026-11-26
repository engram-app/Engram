# kwsearch image. Build context: native/ (the Cargo workspace).
#   docker build -f kwsearch/Dockerfile -t kwsearch native/
# Secrets (token keys, metrics token, feed password, TLS key) are mounted
# files, never baked in. The index lives on a volume at /data/kw.
FROM rust:1.94-bookworm AS build
WORKDIR /src
COPY . .
RUN cargo build --release --locked -p kwsearch

FROM debian:bookworm-slim
RUN useradd --system --uid 10001 --home-dir /data kwsearch && mkdir -p /data/kw && chown kwsearch /data/kw
COPY --from=build /src/target/release/kwsearch /usr/local/bin/kwsearch
USER kwsearch
ENV KW_DATA=/data/kw KW_LISTEN=0.0.0.0:7700
EXPOSE 7700
ENTRYPOINT ["/usr/local/bin/kwsearch"]
CMD ["serve"]

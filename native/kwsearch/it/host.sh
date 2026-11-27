#!/bin/bash
# kwsearch integration harness, host side: a throwaway TLS Postgres and a
# Rust container on one throwaway network, then it/run.sh inside the Rust
# container. Everything it creates is named kwit-* and removed at the end.
#
#   B=<dir holding src/native, target, cargo, rustup> bash host.sh [tests...]
#
# Needs `target/release/kwsearch` built with the harness subcommands
# (`--features harness` on the release build of `-p kwsearch`).
set -euo pipefail
B=${B:?set B to the build dir}
NET=kwit-net PG=kwit-pg RUN=kwit-run
W=$B/it-work
cleanup() { docker rm -f $PG $RUN >/dev/null 2>&1 || true; docker network rm $NET >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup
rm -rf "$W"; mkdir -p "$W/secrets" "$W/pgcerts"
cd "$W/secrets"
# Test CA + server certs for Postgres (kwit-pg) and kwsearch (localhost),
# and a second CA the feed must refuse.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=kwit-ca -keyout ca.key -out ca.crt 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=wrong-ca -keyout wrong.key -out wrong.crt 2>/dev/null
for h in kwit-pg localhost; do
  openssl req -newkey rsa:2048 -nodes -subj /CN=$h -keyout $h.key -out $h.csr 2>/dev/null
  printf "subjectAltName=DNS:%s" $h > $h.ext
  openssl x509 -req -in $h.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile $h.ext -out $h.crt 2>/dev/null
done
cp kwit-pg.crt kwit-pg.key "$W/pgcerts/"; chown 999:999 "$W/pgcerts/"*; chmod 600 "$W/pgcerts/kwit-pg.key"
head -c 24 /dev/urandom | base64 | tr -d '/+=' > pgpw
head -c 24 /dev/urandom | base64 | tr -d '/+=' > feedpw
{ head -c 48 /dev/urandom | base64 | tr -d '/+='; echo; } > tokenkeys
head -c 48 /dev/urandom | base64 | tr -d '/+=' > metricstoken
cp "$B/../kwsearch-it-corpus.jsonl" corpus.jsonl 2>/dev/null || true
cp "$B/queries.json" "$W/queries.json" 2>/dev/null || true
docker network create $NET >/dev/null
docker run -d --name $PG --network $NET -e POSTGRES_PASSWORD="$(cat pgpw)" -v "$W/pgcerts:/certs:ro" \
  postgres:18 -c ssl=on -c ssl_cert_file=/certs/kwit-pg.crt -c ssl_key_file=/certs/kwit-pg.key >/dev/null
until docker exec $PG pg_isready -U postgres >/dev/null 2>&1; do sleep 0.5; done
sleep 1
docker run --rm --name $RUN --network $NET --cpus=8 --memory=12g \
  -v "$B/target:/target" -v "$B/src:/src" -v "$W:/work" -e BIN=/target/release/kwsearch -e KILLS -e SECS -e COLD_N -e TENANTS -e THREADS -e OPS \
  $( [ -d "$B/cold" ] && mountpoint -q "$B/cold" && echo "-v $B/cold:/cold" ) \
  rust:1.94-bookworm bash /src/native/kwsearch/it/run.sh "$@"

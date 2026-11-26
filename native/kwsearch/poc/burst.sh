#!/bin/bash
# Item 2: write burst across many tenants; sample writer RAM / files.
# usage: burst.sh <max_writers> <data dir> [port]
. /secrets/env.sh
MW=$1; export KW_DATA=$2 KW_LISTEN=0.0.0.0:${3:-7701} KW_MAX_WRITERS=$MW KW_WRITER_IDLE_S=10
H=localhost:${3:-7701}/health
rm -rf $KW_DATA; mkdir -p $KW_DATA
$BIN serve > /data/logs/burst-$MW.log 2>&1 & PID=$!
sleep 1; echo "idle-empty: $(curl -s $H)"
T0=$(date +%s)
KW_TENANTS=${TENANTS:-20000} KW_CHUNKS=${CHUNKS:-20} KW_THREADS=8 KW_SEED=$MW $BIN burst
peak=0; want=$(( ${TENANTS:-20000} * ${CHUNKS:-20} ))
r() { echo "$1" | grep -o "\"$2\":[0-9]*" | cut -d: -f2; }
while true; do
  h=$(curl -s $H); rss=$(r "$h" rss_kb)
  [ "${rss:-0}" -gt "$peak" ] && peak=$rss && peakh=$h
  [ "$(r "$h" rows)" -ge "$want" ] && break; sleep 1
done
echo "drained in $(( $(date +%s) - T0 ))s (incl. insert)"
echo "peak: $peakh"
sleep 15; echo "steady (writers idle-closed): $(curl -s $H)"
du -sh $KW_DATA
kill $PID

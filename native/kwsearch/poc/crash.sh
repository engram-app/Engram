#!/bin/bash
# Item 1: kill -9 the writer repeatedly under a live workload, then verify.
. /secrets/env.sh
export KW_DATA=/data/kw1 RUST_BACKTRACE=1
rm -rf $KW_DATA; mkdir -p $KW_DATA /data/logs
start() { (env "$@" $BIN serve >> /data/logs/crash-serve.log 2>&1 & echo $! > /data/serve.pid); sleep 0.5; }
start
KW_TENANTS=300 KW_THREADS=8 KW_SECS=${SECS:-120} $BIN gen > /data/logs/gen.json 2>/data/logs/gen.err & GEN=$!
kills=0
for i in $(seq 1 ${KILLS:-15}); do
  sleep $(( (RANDOM % 6) + 2 ))
  kill -9 $(cat /data/serve.pid); kills=$((kills+1)); sleep 0.5
  if [ $i -eq 5 ] || [ $i -eq 10 ]; then
    # deterministic: abort between two shard commits of one round
    start KW_CRASH_AFTER_COMMITS=$(( (RANDOM % 40) + 3 ))
    sleep 4
    kill -9 $(cat /data/serve.pid) 2>/dev/null; sleep 0.5
  fi
  start
done
wait $GEN
# drain: rows applied stop moving while rounds keep running
drained() { local a b; a=$(curl -s localhost:7700/health); sleep 3; b=$(curl -s localhost:7700/health)
  r() { echo "$1" | grep -o "\"$2\":[0-9]*" | cut -d: -f2; }
  [ "$(r "$a" rows)" = "$(r "$b" rows)" ] && [ $(( $(r "$b" rounds) - $(r "$a" rounds) )) -ge 3 ]; }
until drained; do :; done
curl -s localhost:7700/health; echo
kill -9 $(cat /data/serve.pid); sleep 1
echo "kills=$kills aborts=$(grep -c KW_CRASH_AFTER_COMMITS /data/logs/crash-serve.log) resumes=$(grep -c "feed resume" /data/logs/crash-serve.log)"
cat /data/logs/gen.json
$BIN verify

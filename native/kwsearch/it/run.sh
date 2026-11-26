#!/bin/bash
# kwsearch integration tests (inside the harness container, see host.sh).
# Each test prints PASS/FAIL; the script exits non-zero on any FAIL.
#   tls      the feed reader refuses a Postgres whose cert a wrong CA signed
#   crash    exactly-once under a live workload with kill -9 and aborts
#            between shard commits (task 4a, 4d): index == truth, stats exact
#   panic    a feed-loop panic exits the process (code 70, task 4d)
#   xid      commit-safe reads, tombstones, savepoint xid, tombstones after restart
#   restore  a snapshot taken before deletes serves none of them after a
#            restore, and /health stays down while rows are missing (R3)
set -uo pipefail
S=/work/secrets
export KW_SUPER_URL="postgres://postgres:$(cat $S/pgpw)@kwit-pg:5432/postgres?sslmode=disable"
export KW_FEED_URL="postgres://kwsearch_feed@kwit-pg:5432/postgres" KW_FEED_PASSWORD_FILE=$S/feedpw
export KW_FEED_PW_FILE=$S/feedpw KW_TOKEN_KEYS_FILE=$S/tokenkeys KW_METRICS_TOKEN_FILE=$S/metricstoken
export KW_FEED_CA_FILE=$S/ca.crt KW_CA_FILE=$S/ca.crt KW_TLS_CERT=$S/localhost.crt KW_TLS_KEY=$S/localhost.key
export KW_LISTEN=127.0.0.1:7700 KW_URL=https://localhost:7700 RUST_BACKTRACE=1
H="curl -s --cacert $S/ca.crt https://localhost:7700/health"
LOG=/work/logs; mkdir -p $LOG
fails=0
pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2"; fails=$((fails+1)); }
start() { (env "$@" $BIN serve >> $LOG/serve.log 2>&1 & echo $! > /work/serve.pid); }
stop() { kill -9 "$(cat /work/serve.pid)" 2>/dev/null; sleep 0.5; }
up() { for _ in $(seq 1 ${1:-100}); do $H | grep -q '"up":true' && return 0; sleep 0.2; done; return 1; }
psql_() { PGPASSWORD=$(cat $S/pgpw) psql -h kwit-pg -U postgres -qAt -c "$1"; }
command -v psql >/dev/null || (apt-get update -qq && apt-get install -y -qq postgresql-client >/dev/null)
$BIN schema >/dev/null
# Each test starts from an empty feed: a horizon left by the restore test
# would read as a gap to a fresh index.
# Drained: the applied cursor (/cursor, ops token) has reached the feed's
# last row, i.e. a whole round committed past it. lag_s alone is not enough:
# it reads 0 right after a drained read, before the next round commits.
drained() {
  local want got
  want=$(psql_ "SELECT xid::text || ' ' || seq FROM keyword_feed ORDER BY xid DESC, seq DESC LIMIT 1")
  [ -n "$want" ] || return 0
  got=$(curl -s --cacert $S/ca.crt -H "authorization: Bearer $($BIN token ops)" https://localhost:7700/cursor \
        | sed -E 's/.*"seq":([0-9]+).*"xid":"([0-9]+)".*/\2 \1/')
  [ "$(printf '%s\n%s\n' "$want" "$got" | sort -n -k1,1 -k2,2 | tail -1)" = "$got" ]
}
wait_drained() { for _ in $(seq 1 ${1:-600}); do drained && return 0; sleep 1; done; return 1; }
reset() { psql_ "TRUNCATE keyword_feed, keyword_deletions, truth_users, truth_vaults, truth_notes, truth_chunks; DELETE FROM keyword_feed_horizon"; }

t_tls() {
  reset
  export KW_DATA=/work/kw-tls; rm -rf $KW_DATA
  start KW_FEED_CA_FILE=$S/wrong.crt
  sleep 4
  if ! up 5 && grep -q "feed connect failed" $LOG/serve.log; then pass tls "wrong CA refused, never up"; else fail tls "connected or came up with a wrong CA"; fi
  stop
}

t_crash() {
  reset
  export KW_DATA=/work/kw-crash; rm -rf $KW_DATA; mkdir -p $KW_DATA
  : > $LOG/serve.log
  start; up || { fail crash "never up"; return; }
  KW_TENANTS=${TENANTS:-300} KW_THREADS=${THREADS:-8} KW_SECS=${SECS:-90} $BIN gen > $LOG/gen.json 2>$LOG/gen.err & GEN=$!
  kills=0
  for i in $(seq 1 ${KILLS:-12}); do
    sleep $(( (RANDOM % 5) + 2 ))
    stop; kills=$((kills+1))
    if [ $((i % 4)) -eq 0 ]; then
      start KW_CRASH_AFTER_COMMITS=$(( (RANDOM % 40) + 3 )); sleep 4; stop
    fi
    start
  done
  wait $GEN
  up 300
  wait_drained || { fail crash "never drained"; stop; return; }
  stop
  out=$($BIN verify 2> $LOG/verify.err); code=$?
  [ $code -eq 0 ] || explain
  echo "$out"; cat $LOG/gen.json
  echo "kills=$kills aborts=$(grep -c KW_CRASH_AFTER_COMMITS $LOG/serve.log) resumes=$(grep -c 'feed resume' $LOG/serve.log)"
  if [ $code -eq 0 ]; then pass crash "$out"; else fail crash "$out"; fi
}

t_panic() {
  reset
  export KW_DATA=/work/kw-panic; rm -rf $KW_DATA
  KW_PANIC_AFTER_ROUNDS=3 timeout 60 $BIN serve >> $LOG/panic.log 2>&1; code=$?
  if [ $code -eq 70 ] && grep -q "feed loop died" $LOG/panic.log; then pass panic "exit 70"; else fail panic "exit $code"; fi
}

t_xid() {
  reset
  export KW_DATA=/work/kw-xid; rm -rf $KW_DATA
  start; up || { fail xid "never up"; return; }
  out=$($BIN xidtest); code=$?
  echo "$out"
  [ $code -eq 0 ] && pass xid "commit-safe + tombstones + savepoint" || fail xid "$out"
  late=$(echo "$out" | grep -o '"delete_user":{[^}]*' | grep -o '"user":"[^"]*' | cut -d'"' -f4)
  stop; start; up || { fail xid-restart "never up"; return; }
  out=$(KW_LATE_USER=$late $BIN xidtest); code=$?
  [ $code -eq 0 ] && pass xid-restart "$out" || fail xid-restart "$out"
  stop
}

t_restore() {
  reset
  export KW_DATA=/work/kw-restore; rm -rf $KW_DATA /work/kw-snap
  start; up || { fail restore "never up"; return; }
  ua=00000000-0000-4000-8000-0000000000a1; va=00000000-0000-4000-8000-0000000000a2
  ub=00000000-0000-4000-8000-0000000000b1; vb=00000000-0000-4000-8000-0000000000b2
  uc=00000000-0000-4000-8000-0000000000c1; vc=00000000-0000-4000-8000-0000000000c2
  for u in $ua $ub $uc; do
    v=${u%1}2
    for n in 3 4; do
      psql_ "INSERT INTO keyword_feed (user_id, op, vault_id, note_id, point_id, stamp, terms)
             VALUES ('$u', 1, '$v', '${u%1}$n', gen_random_uuid(), 1, '\\x0700000001000000')"
    done
  done
  wait_drained 60; stop
  cp -a $KW_DATA /work/kw-snap   # the "snapshot"
  start; up || { fail restore "never up after snapshot"; return; }
  # After the snapshot: delete user A, vault B, one note of C (feed + log).
  psql_ "BEGIN; INSERT INTO keyword_feed (user_id, op) VALUES ('$ua', 5); INSERT INTO keyword_deletions (user_id, op) VALUES ('$ua', 5);
         INSERT INTO keyword_feed (user_id, op, vault_id) VALUES ('$ub', 4, '$vb'); INSERT INTO keyword_deletions (user_id, op, vault_id) VALUES ('$ub', 4, '$vb');
         INSERT INTO keyword_feed (user_id, op, vault_id, note_id, stamp) VALUES ('$uc', 3, '$vc', '${uc%1}3', 2);
         INSERT INTO keyword_deletions (user_id, op, vault_id, note_id) VALUES ('$uc', 3, '$vc', '${uc%1}3'); COMMIT;"
  wait_drained 60; stop
  # The feed is trimmed (it was applied); the trim records its horizon.
  psql_ "INSERT INTO keyword_feed_horizon (id, xid, seq) SELECT 1, max(xid), max(seq) FROM keyword_feed
         ON CONFLICT (id) DO UPDATE SET xid = EXCLUDED.xid, seq = EXCLUDED.seq; TRUNCATE keyword_feed"
  # Restore the snapshot and boot it.
  rm -rf $KW_DATA; cp -a /work/kw-snap $KW_DATA
  : > $LOG/serve.log
  start; sleep 5
  health=$($H)
  stop
  a=$($BIN stats $ua); b=$($BIN stats $ub); c=$($BIN stats $uc)
  echo "health=$health A=$a B=$b C=$c restored=$(grep -o '[0-9]* deletion-log deletes applied' $LOG/serve.log)"
  if echo "$health" | grep -q '"up":false' && [ "$a" = "0 0" ] && [ "$b" = "0 0" ] && [ "${c%% *}" = "1" ]; then
    pass restore "deletes applied before serving, down until rebuild"
  else
    fail restore "health=$health A=$a B=$b C=$c"
  fi
}

# Latency with maintained per-user stats: the eval corpus x12 (193k chunks)
# plus 200 filler tenants in its shard. Warm over keep-alive HTTPS for the
# four filter cases; cold = per query, evict every index file from the page
# cache (needs /cold: xfs on a zvol with primarycache=metadata), start a
# read-only node, run one query. Not part of the default set.
t_bench() {
  reset
  Q=/work/queries.json O=/work/out; mkdir -p $O
  export KW_DATA=/work/kw-bench KW_CORPUS=$S/corpus.jsonl KW_REPS=12; rm -rf $KW_DATA
  KW_FILLERS=200 KW_FILLER_CHUNKS=800 $BIN load-eval | tee $O/load.json
  start; up 600
  wait_drained 900
  stop
  start KW_READ_ONLY=1; up
  for cfg in "0 0" "10240 0" "0 10240" "10240 10240"; do
    set -- $cfg
    KW_INCLUDE=$1 KW_EXCLUDE=$2 KW_PASSES=3 $BIN bench $Q warm $O/warm-$1-$2.json
  done
  stop
  [ -d /cold ] || { echo "no /cold mount: cold bench skipped"; return; }
  rm -rf /cold/kw; cp -a $KW_DATA /cold/kw; sync
  : > $O/cold.lines
  for i in $(seq 0 ${COLD_N:-59}); do
    find /cold/kw -type f -exec dd if={} iflag=nocache count=0 status=none \;
    KW_DATA=/cold/kw start KW_READ_ONLY=1; up 200
    KW_DATA=/cold/kw KW_SKIP=$((i*3)) KW_N=1 $BIN bench $Q cold $O/cold-one.json >/dev/null
    grep -o '"p50": [0-9.]*' $O/cold-one.json | head -1 | awk '{print $2}' >> $O/cold.lines
    stop
  done
  sort -n $O/cold.lines | awk '{a[NR]=$1} END {printf "cold n=%d p50=%s p95=%s max=%s\n", NR, a[int(NR*0.5)+1], a[int(NR*0.95)+1], a[NR]}'
  pass bench "see numbers above"
}

# The feed rows of the note behind one missing and one extra point.
explain() {
  cat $LOG/verify.err
  for kind in missing extra; do
    p=$(grep "$kind sample" $LOG/verify.err | grep -oE '[0-9a-f-]{36}' | head -1)
    [ -n "$p" ] || continue
    echo "== $kind $p"
    psql_ "SELECT note_id FROM keyword_feed WHERE point_id = '$p' LIMIT 1"
    psql_ "SELECT xid, seq, op, stamp, point_id = '$p' AS this, array_length(keep, 1), '$p' = ANY(keep) AS kept FROM keyword_feed
           WHERE note_id = (SELECT note_id FROM keyword_feed WHERE point_id = '$p' LIMIT 1) ORDER BY xid, seq"
  done
}

# The whole feed applied in one catch-up from an empty index: big rounds,
# and xids past a digit-count boundary (the text-sorted xid bug).
t_replay() {
  reset
  export KW_DATA=/work/kw-replay; rm -rf $KW_DATA
  KW_TENANTS=${TENANTS:-30} KW_THREADS=${THREADS:-8} KW_SECS=${SECS:-20} KW_OPS=${OPS:-0} $BIN gen > /dev/null
  start; up 300; wait_drained; stop
  if $BIN verify 2> $LOG/verify.err; then pass replay "$(tail -1 $LOG/verify.err)"; else explain; fail replay "mismatch"; fi
}

for t in ${@:-tls replay crash panic xid restore}; do "t_$t"; done
echo "integration: $fails failed"
exit $fails

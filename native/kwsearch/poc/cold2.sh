#!/bin/bash
# Cold-read attribution: per query, evict, start, one query, then count the
# index bytes the query pulled into the page cache (fincore).
. /secrets/env.sh
export KW_LISTEN=0.0.0.0:7702 KW_URL=http://127.0.0.1:7702 KW_DATA=/cold/kwl KW_REPS=12 KW_FEED_URL=
H=localhost:7702/health
for mode in ${MODES:-1 0}; do
  for i in $(seq 0 19); do
    find /cold/kwl -type f -exec dd if={} iflag=nocache count=0 status=none \;
    ($BIN serve > /dev/null 2>&1 & echo $! > /data/c2.pid); until curl -sf $H >/dev/null; do sleep 0.05; done
    opened=$(find /cold/kwl -type f -exec fincore -nb -o RES {} \; | awk "{s+=\$1} END {print s+0}")
    KW_SHARD_STATS=$mode KW_SKIP=$((i*37)) KW_N=1 $BIN bench /secrets/queries.json cold /data/c2.json > /dev/null
    after=$(find /cold/kwl -type f -exec fincore -nb -o RES {} \; | awk "{s+=\$1} END {print s+0}")
    ms=$(grep -A3 "\"all\"" /data/c2.json | grep p50 | grep -o "[0-9.]*")
    echo "shard_stats=$mode q=$i ms=$ms open_bytes=$opened query_bytes=$((after-opened))"
    kill $(cat /data/c2.pid); sleep 0.3
  done
done

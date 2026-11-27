#!/bin/bash
# Items 3-5: quality parity, index size, latency (warm / after restart / cold).
. ${ENVF:-/secrets/env.sh}
Q=/secrets/queries.json; O=/data/out; mkdir -p $O /data/logs
H=localhost:7702/health
export KW_URL=http://127.0.0.1:7702
r() { echo "$1" | grep -o "\"$2\":[0-9]*" | cut -d: -f2; }
drain() { local prev=-1 same=0; while true; do h=$(curl -s $H); x=$(r "$h" rows); [ "$x" = "$prev" ] && same=$((same+1)) || same=0; prev=$x; [ $same -ge 4 ] && break; sleep 1; done; }
serve() { (env "$@" KW_LISTEN=0.0.0.0:7702 $BIN serve >> /data/logs/search-serve.log 2>&1 & echo $! > /data/search.pid); until curl -sf $H >/dev/null; do sleep 0.1; done; }
stop() { kill $(cat /data/search.pid) 2>/dev/null; sleep 1; }

part=${1:-all}
if [ $part = quality ] || [ $part = all ]; then
  # A: eval tenant alone (1x). B: + 200 fillers (800 chunks each) in its shard.
  export KW_DATA=/data/kwq; rm -rf $KW_DATA
  KW_REPS=1 KW_FILLERS=0 $BIN load-eval | tee $O/load-a.json
  serve KW_FEED_URL=$KW_FEED_URL; drain
  S=$(grep -o "\"shard\":[0-9]*" $O/load-a.json | cut -d: -f2)
  KW_SHARD=$S $BIN du | tee $O/size-1x.json
  KW_REPS=1 $BIN bench $Q quality $O/run-alone.json
  KW_REPS=1 $BIN bench $Q quality_shard $O/run-alone-shardstats.json
  KW_REPS=0 KW_FILLERS=200 KW_FILLER_CHUNKS=800 $BIN load-eval | tee $O/load-b.json
  drain
  KW_SHARD=$S $BIN du | tee $O/size-shared.json
  KW_REPS=1 $BIN bench $Q quality $O/run-shared.json
  KW_REPS=1 $BIN bench $Q quality_shard $O/run-shared-shardstats.json
  stop
fi
if [ $part = latency ] || [ $part = all ]; then
  # C: eval tenant x12 (193k chunks) + 200 fillers in its shard.
  export KW_DATA=/data/kwl; rm -rf $KW_DATA
  KW_REPS=12 KW_FILLERS=200 KW_FILLER_CHUNKS=800 $BIN load-eval | tee $O/load-c.json
  serve KW_FEED_URL=$KW_FEED_URL; drain
  S=$(grep -o "\"shard\":[0-9]*" $O/load-c.json | cut -d: -f2)
  KW_SHARD=$S $BIN du | tee $O/size-12x.json
  stop; serve   # no feed: a read-only search node from here on
  export KW_REPS=12
  for cfg in "0 0 0" "10240 0 0" "0 10240 0" "10240 0 1" "10240 10240 1"; do
    set -- $cfg
    KW_INCLUDE=$1 KW_EXCLUDE=$2 KW_B64=$3 $BIN bench $Q warm $O/warm-$1-$2-$3.json
  done
  # After a restart on ZFS (ARC keeps file pages; not truly cold).
  stop; serve; KW_N=60 $BIN bench $Q cold $O/restart-zfs.json
  stop
  # true cold on an xfs zvol of the NVMe cache pool, primarycache=metadata: before EACH query, stop, evict every index file from
  # the page cache (dd iflag=nocache = POSIX_FADV_DONTNEED), check fincore, start.
  rm -rf /cold/kwl; cp -a $KW_DATA /cold/kwl; export KW_DATA=/cold/kwl; sync
  : > $O/cold-xfs.lines; res=0
  for i in $(seq 0 59); do
    find /cold/kwl -type f -exec dd if={} iflag=nocache count=0 status=none \;
    res=$(( res + $(find /cold/kwl -type f -exec fincore -nb -o RES {} \; | awk "{s+=\$1} END {print s+0}") ))
    serve; KW_SKIP=$((i*13)) KW_N=1 $BIN bench $Q cold $O/cold-one.json >/dev/null; cat $O/cold-one.json >> $O/cold-xfs.lines; stop
  done
  echo "{\"cold_resident_bytes_total\": $res}" > $O/cold-resident.json
fi

#!/usr/bin/env bash
# Snapshot CRDT room allocation from a running engram container.
#
# Why this exists: the headline question for the room-decoupling work is "how
# many rooms did that import allocate, and which path allocated them". Answering
# it on staging costs a deploy per iteration. Everything needed is already in
# the release — PromEx holds the counters and `bin/engram rpc` can read them
# without the metrics endpoint's auth — so the same measurement runs against a
# local stack in seconds.
#
# Read `room_start` (rooms ARRIVING), not residency. Residency is instantaneous
# and, with an idle drain, a burst of rooms can come and go entirely between two
# samples: the 2026-08-19 staging import peaked at 316 resident while actually
# allocating 406, and the 316 turned out to be the LRU's eviction rate rather
# than demand.
#
# Usage:
#   scripts/crdt-room-metrics.sh                     # default local CRDT stack
#   scripts/crdt-room-metrics.sh <container>
#   scripts/crdt-room-metrics.sh <container> --json
#
# Typical loop:
#   scripts/crdt-room-metrics.sh > before.txt
#   ...run the import...
#   scripts/crdt-room-metrics.sh > after.txt
#   diff before.txt after.txt
#
# Counters are cumulative since BOOT, so a container restart resets them.
# `booted_at` is printed for exactly that reason: if it moved between two
# snapshots, the delta is meaningless.
set -euo pipefail

CONTAINER="${1:-engram-crdt-engram-1}"
FORMAT="${2:-text}"

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "no such container: $CONTAINER" >&2
  echo "running engram containers:" >&2
  docker ps --format '  {{.Names}}' | grep -i engram >&2 || true
  exit 1
fi

# Runs inside the release. Kept to one rpc call so the snapshot is coherent
# rather than smeared across several round trips.
read -r -d '' SCRIPT <<'ELIXIR' || true
scrape =
  try do
    PromEx.get_metrics(Engram.PromEx) |> to_string()
  rescue
    _ -> ""
  end

rooms =
  :global.registered_names()
  |> Enum.count(fn
    {:crdt_doc, _} -> true
    _ -> false
  end)

lines =
  scrape
  |> String.split("\n")
  |> Enum.filter(&String.starts_with?(&1, "engram_prom_ex_crdt_room_"))
  |> Enum.reject(&String.starts_with?(&1, "engram_prom_ex_crdt_room_start_total{source=\"\"}"))
  |> Enum.sort()

{uptime_ms, _} = :erlang.statistics(:wall_clock)

IO.puts("booted_at_ms_ago=#{uptime_ms}")
IO.puts("rooms_resident=#{rooms}")
IO.puts("processes=#{:erlang.system_info(:process_count)}")
IO.puts("memory_total_mb=#{div(:erlang.memory(:total), 1024 * 1024)}")
Enum.each(lines, &IO.puts/1)
ELIXIR

OUT="$(docker exec "$CONTAINER" bin/engram rpc "$SCRIPT")"

if [ "$FORMAT" = "--json" ]; then
  # Deliberately naive: keys here are already `k=v` or Prometheus `name{tags} v`.
  # Enough for piping into jq during a measurement loop, not a general exporter.
  printf '%s\n' "$OUT" | awk '
    BEGIN { print "{"; first = 1 }
    /=/ && !/[{ ]/ { split($0, kv, "="); k = kv[1]; v = kv[2] }
    /^engram_/ { n = split($0, f, " "); k = f[1]; v = f[n] }
    k != "" {
      if (!first) printf ",\n"; first = 0
      gsub(/"/, "\\\"", k)
      printf "  \"%s\": %s", k, v
      k = ""
    }
    END { print "\n}" }'
else
  printf '%s\n' "$OUT"
fi

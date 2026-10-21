#!/usr/bin/env bash
# Server-side sampler for a load-sim run against staging-fastraid. Read-only:
# psql under default_transaction_read_only, `docker stats`/`docker logs`, and a
# PromEx scrape through the release rpc. Needs SSH to the staging host, so it
# runs next to (not inside) the CI job: `e2e/load/server_probe.sh <out_dir> [interval_s] [duration_s]`.
set -u
OUT=${1:?out dir}; INTERVAL=${2:-60}; DURATION=${3:-9000}
HOST=${STAGING_HOST:-root@10.0.20.214}; APP=${STAGING_APP:-engram-saas}; PG=${STAGING_PG:-engram-saas-postgres}
mkdir -p "$OUT"
end=$(( $(date +%s) + DURATION )); n=0; since=$(date -u +%Y-%m-%dT%H:%M:%SZ)

sql() { ssh -o BatchMode=yes "$HOST" "docker exec -i $PG psql -U engram -d engram -X -At -F'|' -c 'SET default_transaction_read_only = on' -f -" | sed '1d'; }

while [ "$(date +%s)" -lt "$end" ]; do
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  sql > "$OUT/db-$n.txt" <<'SQL'
select 'oban', state, queue, count(*) from oban_jobs group by 2,3;
select 'oban_stuck_executing', count(*) from oban_jobs where state='executing' and attempted_at < now() - interval '10 minutes';
select 'oban_new_discards_1h', queue, count(*) from oban_jobs where state='discarded' and discarded_at > now() - interval '1 hour' group by 2;
select 'oban_oldest_completed_h', round(extract(epoch from now() - min(completed_at))/3600, 1) from oban_jobs where state='completed';
select 'oban_peers', name, node, expires_at > now() from oban_peers;
select 'conns', usename, coalesce(state,'-'), count(*) from pg_stat_activity where datname='engram' group by 2,3;
select 'idle_in_txn_gt_30s', count(*) from pg_stat_activity where state like 'idle in transaction%' and now()-state_change > interval '30 seconds';
select 'waiting_locks', count(*) from pg_locks where not granted;
select 'tbl', relname, seq_scan, idx_scan, n_tup_ins, n_tup_upd, n_tup_hot_upd, n_tup_del, n_live_tup, n_dead_tup from pg_stat_user_tables where relname in ('oban_jobs','notes','chunks','note_revisions','crdt_update_log','vaults','usage_meters','oauth_refresh_tokens','device_refresh_tokens');
select 'idx', indexrelname, idx_scan from pg_stat_user_indexes where indexrelname in ('notes_vault_path_tombstone_index','notes_reconcile_due','note_revisions_pending_by_note','attachments_vault_path_tombstone_index','oauth_refresh_tokens_consumed_unrevoked_index','device_refresh_tokens_unrevoked_expires_at_index','note_links_target_note_id_index','notes_user_vault_path_v2');
select 'deadlocks', deadlocks, xact_rollback, xact_commit, temp_files from pg_stat_database where datname='engram';
SQL
  ssh -o BatchMode=yes "$HOST" "docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' $APP $PG" > "$OUT/stats-$n.txt" 2>&1
  # Warnings/errors since the previous sample (JSON log lines carry "severity").
  ssh -o BatchMode=yes "$HOST" "docker logs --since $since $APP 2>&1" \
    | grep '^{' | grep -E '"severity":"(warning|error|critical|alert|emergency)"' > "$OUT/logs-$n.jsonl" || true
  since=$ts
  if [ $(( n % 5 )) -eq 0 ]; then
    ssh -o BatchMode=yes "$HOST" "docker exec $APP bin/engram rpc 'IO.puts(PromEx.get_metrics(Engram.PromEx))'" 2>/dev/null \
      | grep -E '^engram_prom_ex_(crdt|oban_job|websocket|phoenix_channel|ecto|repo)' > "$OUT/prom-$n.txt" || true
  fi
  echo "$ts $n" >> "$OUT/samples.txt"
  n=$((n + 1))
  sleep "$INTERVAL"
done

# Staging traffic simulator

Prod-shaped load against a deployed Engram, for release gates and rehearsals.
Staging has no real users, so a passive soak proves nothing; this generates the
traffic instead.

| File | What |
|---|---|
| `sim.py` | Orchestrator: accounts, seeding, REST/MCP/WS/OAuth traffic, churn, mid-run vault purge, summary |
| `crdt_load.ts` | CRDT half: two devices per account on the real plugin engine (`e2e/headless` Replica) |
| `server_probe.sh` | Server-side sampler (Oban, pg_stat_*, connections, logs, PromEx). Needs SSH to the staging host |
| `grant.sql` | One-time limit grant for the sim's accounts |
| `.github/workflows/staging-load.yml` | `workflow_dispatch` runner for `sim.py` |

## Workload

- 20 Clerk accounts `load-sim-uNN+clerk_test@example.com`, reused across runs.
  Vault sizes mirror prod's skew (p50 1, p90 70, p99 1158, max 10k): one 10k
  whale, three 1k, the rest 300 down to 1. Frontmatter-heavy notes, folders up
  to 6 deep, wikilinks, PNG attachments, three ~300 KB notes and one base64
  inline-image note.
- Rates are multiples of prod's 24h mean (`RATES` in `sim.py`, measured
  2026-10-20: 0.74 HTTP req/s + 1.75 WS frames/s). Default: 10 min warmup,
  steady 10x, a 5 min 30x burst at t=3600 s, 2 h total.
- Churn (rename, folder move, delete + restore, pushes) only touches the
  `Churn/` notes, and every write toggles between two known contents, so the
  corpus stays put between runs.

## Running

```bash
# once per target: create the accounts, then grant them (needs DB access)
STAGING_CLERK_SECRET_KEY=... python3 e2e/load/sim.py --provision-only
ssh root@10.0.20.214 "docker exec -i engram-saas-postgres psql -U engram -d engram" < e2e/load/grant.sql

# each run (CI: Actions > staging-load > Run workflow)
STAGING_CLERK_SECRET_KEY=... ENGRAM_PLUGIN_SRC=../plugin \
  systemd-run --user --scope -p MemoryMax=4G -p CPUQuota=200% \
  python3 e2e/load/sim.py --duration 7200 --out load-out
e2e/load/server_probe.sh probe-out 60 9000   # alongside, from a host with SSH to staging
```

Output: `load-out/summary.md` (p50/p95/p99 and errors per op, per phase),
`summary.json`, raw `ops.jsonl` + `crdt_ops.jsonl`.

## Safety

- **Target allowlist.** `--api` defaults to staging and must be a host in
  `guards.STAGING_HOSTS` (staging, the FastRaid LAN host, localhost);
  anything else needs `--i-know-this-is-not-staging`. It is never read from
  `ENGRAM_API_URL`. A `sk_live_` Clerk key is refused.
- **Secrets.** The CRDT config (live API keys) goes to a 0600 tempfile
  outside `--out` and is deleted after the run; the artifact upload also
  excludes it. The bun child gets no Clerk key. Each run revokes the
  accounts' earlier API keys and device families, and its own at the end.

## Spend guard

Staging embeds with real Voyage (`voyage-4-large`, $0.12/M tokens). The full
corpus is about 4.4M tokens (~$0.53) and is written once: later runs seed only
what the manifest lacks. Before anything is written, the sim estimates the
missing notes and stops if that exceeds `--max-seed-tokens` (12M). A running
cap, `--max-embed-tokens` (20M, ~$2.40), is reserved before every embedding
write (seed, the purge re-seed, traffic pushes and MCP writes); writes past it
are skipped and recorded as `spend_cap`. CRDT edits run in the bun process and
are not counted; they are tiny (a few dozen tokens per edit).

## Limits the sim needs

`grant.sql` lifts, for these accounts only: `notes_cap` (whale), 
`ai_searches_per_day` (Free: 20), `concurrent_devices` and
`obsidian_connections_cap` (Free: 2). The per-IP `/auth/device*` bucket
(10/min) is shared by the whole sim, so OAuth refresh is capped at 0.12/s.

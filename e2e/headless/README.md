# Headless protocol tier

Boots the **real** plugin `SyncEngine` + `CrdtManager` + `NoteChannel`
headless (obsidian shimmed, vault = a real temp-dir fs) and drives them
against the **real** backend over **real** WebSockets in **real** time. Its job
is the *protocol*: prove the real server persists and delivers over real
Phoenix channels — the thing the client-only convergence sim tier cannot see by
construction (the sim runs against a MODEL of the server).

It reuses ONLY the sim tier's `tests/sim/obsidian-shim.ts` + `tests/sim/vault-fs.ts`
and transcribes `src/main.ts`'s boot wiring order. It does **not** use the sim's
scheduler / clock / model-server — this tier is real time + real server, so
convergence is awaited on real signals via **event barriers**, never wall-clock
sleeps.

## Running it

```bash
# 1. Bring up the CI stack (see docs/context/local-crdt-e2e-repro.md):
export ENCRYPTION_MASTER_KEY='nz9JqBx8cSw/DOjVorxQDGcs6UvW2J45NDrkDo1k02E='
export CRDT_ENABLED=true CI_PG_PORT=5439
docker compose -f ci/compose.yml -f ci/compose.local.yml -p engram-headless up -d --no-build --wait
#    (build once first if the engram image is absent — needs HEX_MIRROR:
#     HEX_MIRROR=http://10.0.20.214:8090 docker compose ... -p engram-headless build engram)

# 2. Run the tier (points at the mapped engram port; find it via `docker compose ... ps`):
ENGRAM_PLUGIN_SRC=/path/to/plugin/worktree \
ENGRAM_API_URL=http://localhost:8100/api \
CI_POSTGRES_CONTAINER=engram-headless-postgres-1 \
  bun --preload ./e2e/headless/preload.ts ./e2e/headless/run.ts
```

Exit 0 = all GREEN gate scenarios passed. Exit 1 = a GREEN scenario failed or
setup failed. Env: `E2E_DELIVERY_TIMEOUT` (seconds, default 120 — the
true-breakage bound), `CI_POSTGRES_CONTAINER` (for the plan-override grant).

## Cross-repo dependency (CI ordering)

This tier imports the plugin's `tests/sim/obsidian-shim.ts`, `tests/sim/vault-fs.ts`,
and `tests/__mocks__/obsidian.ts` from `ENGRAM_PLUGIN_SRC`. Those sim adapters
currently live on the plugin branch `feat/convergence-sim-tier` (P1). The
`headless-protocol` CI job checks the plugin out at the paired `PLUGIN_SHA`, so
it goes green only once that branch is on plugin `main` (or when this backend PR
is paired with the plugin branch via the `plugin_branch` dispatch input). Until
then the job's import step will fail against plugin `main` — expected, and it
resolves when the sim tier merges.

## Barriers (`barriers.ts`)

Event-driven, never sleep-then-assert:

- **`synced(replica)`** — resolves on the engine's post-join/catch-up-complete
  signal. The real signal is the seq-cursor persist: `catchupViaSeqReplay` calls
  the engine's `saveData` hook with a `catchupSeq` key at the end of every
  replay pass (`src/sync.ts:3448`). `boot()` feeds that hook into a
  `CatchupSignal` — no new plumbing, no timer. Pass a prior `catchupCount` to
  wait for a NEW catch-up (arm before a reconnect).
- **`noteVisible(replica, path, hash)`** — assert-polls the replica's real vault
  file at ≤100 ms until its sha256 matches, deadline = `E2E_DELIVERY_TIMEOUT`
  (120 s true-breakage bound), not a padded sleep.
- **`serverHasContent(...)`** — assert-polls REST `GET /notes/{path}` until the
  server durably holds the content. Gating a receiver's catch-up on this real
  condition (not a fixed wait) is what makes the catch-up scenarios
  deterministic rather than racing A's server-side persist.

## Scenarios

GREEN gate (every scenario must pass — proven green + deterministic on current
main, burned in 5/5 locally before the job was promoted to required; each < 3 s):

1. **handshake** — two devices join the `crdt:` room + complete catch-up.
2. **create → server persists** — A creates a note; the server durably holds the
   content (A → server, over the real CRDT protocol).
3. **late-joiner catch-up** — a fresh replica that joins after the note exists
   converges via its initial catch-up (server → new replica).
4. **reconnect catch-up** — B goes offline, A creates a note, B reconnects and
   converges (server → reconnecting replica).
5. **live A→B fan-out** — both replicas stay enrolled/live; A creates then
   live-edits a note; B converges via the live socket push (`note_yjs_update`
   fan-out), NOT a reconnect catch-up. This is the path that was RED pre-plugin
   `#282`; see the payload note below.
6. **stale head after room recreate (`#285`)** — the room is killed out from
   under the live devices via the `backend_rpc` `terminate_room` seam, an edit
   recreates it with a new head, and a reconnecting replica MUST read the new
   head — not the stale pre-terminate one. RED pre-backend `#1073`.

### What the green gate proves

The catch-up scenarios (1–4) exercise **catch-up delivery (server → replica) +
server persistence**. Scenario 5 adds **live real-time A→B fan-out**, and
scenario 6 the **stale-head-after-recreate** protocol invariant. Together they
are the deterministic replacement for the demoted plugin↔backend contract e2e.

### Deferred scenarios

Not yet in the gate, disclosed so a reader does not assume they're covered:

- **`offline-queue flush`** — achievable via catch-up; good next addition.
- **`rename both-paths`** (old path cleaned + new path delivered) — deferred.

## Known payloads (the reason this tier exists)

Two protocol/server bugs the sim tier cannot catch — both fixed on main and now
gated **green** (they were RED before their fixes; this tier is what proves the
fix and would catch a regression):

- **`#282` (equal-seq fence collision masks heal)** — a live `note_yjs_update` to
  an idle receiver could stamp the per-path fence (`syncState.seq`) with a seq
  whose content never applied, so the follow-up seq-replay saw the content op at
  `seq ≤ fence` and SKIPPED it as history — the note stuck empty. Fixed by the
  content-hash-aware equal-seq fence (plugin `#296`): an equal-seq row carrying
  new content is no longer dropped. Gated by scenario 5 (**live A→B fan-out**).

- **stale head after room recreate (`#285`)** — a room recreated by a post-
  `terminate_room` edit could serve a **stale head** to a reconnecting replica.
  Fixed by backend `#1073` (stale-head-after-recreate + head-consistency
  property). Gated deterministically by scenario 6 via the `backend_rpc`
  `terminate_room` seam (`e2e/helpers/backend_rpc.py` equivalent, in `run.ts`).

## File map

| File | Role |
|---|---|
| `preload.ts` | `bun --preload`: aliases `obsidian` → the sim shim, shims `window`, installs `fake-indexeddb` (all sourced from `ENGRAM_PLUGIN_SRC`). |
| `barriers.ts` | `CatchupSignal` + `synced` / `noteVisible` / `serverHasContent` event barriers. |
| `run.ts` | REST setup (register + plan grant + api-key + vault), the headless `Replica` boot (main.ts wiring order), and the scenarios. |

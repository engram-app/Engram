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

GREEN gate (must pass — proven green + deterministic on current main, each < 1 s):

1. **handshake** — two devices join the `crdt:` room + complete catch-up.
2. **create → server persists** — A creates a note; the server durably holds the
   content (A → server, over the real CRDT protocol).
3. **late-joiner catch-up** — a fresh replica that joins after the note exists
   converges via its initial catch-up (server → new replica).
4. **reconnect catch-up** — B goes offline, A creates a note, B reconnects and
   converges (server → reconnecting replica).

### What the green gate proves (do NOT over-read it)

All four green scenarios exercise **catch-up delivery (server → replica) + server
persistence** over the real CRDT protocol. The gate does **NOT** prove **live
real-time A→B fan-out** — that path is deliberately not gated (see below). A
green run means "the server persists and a replica converges on catch-up", not
"a live edit on A reached B in real time".

### Deferred scenarios

Not yet in the gate. Disclosed with the same discipline as the `#282`/`#285`
payloads below so a reader does not assume they're covered:

- **`edit → deliver`** — achievable via catch-up WITHOUT `#282` (it's the same
  server→replica convergence path as create). Deferred; good next addition.
- **`offline-queue flush`** — likewise achievable via catch-up without `#282`.
  Deferred; good next addition.
- **`rename both-paths`** (old path cleaned + new path delivered) — deferred.
- **live A→B fan-out** — **NOT gated.** Blocked by the open plugin `#282` (fence
  v≤v collision masks heal) that this tier already *reproduces* deterministically
  (the `HEADLESS_REPRO_282=1` scenario, reported known-red). A live
  `note_yjs_update` to an idle receiver is exactly the path `#282` breaks, so a
  live fan-out scenario cannot be a green gate until `#282` lands. This is why
  the green gate above is catch-up-only.
- **stale-head `#285` regression** — TODO; needs the `#285` server fix (`#1073`)
  in the image. See the payload note below.

## Known payloads (the reason this tier exists)

Two protocol/server bugs the sim tier cannot catch:

- **`#282` (fence v≤v collision masks heal)** — REPRODUCED here deterministically
  by the `HEADLESS_REPRO_282=1` scenario (LIVE delivery to an idle, never
  live-bound receiver). A live `note_yjs_update` to such a receiver routes
  through `adoptHistoryLessNote` → REST `getUpdates`; that pull loses a commit
  race (404) so the content never applies, but the op's seq still stamps the
  per-path fence (`syncState.seq`). The follow-up seq-replay then sees the
  content op at `seq ≤ fence` and SKIPS it as history — the note is stuck empty.
  Confirmed against the running image: the SAME note converges cleanly for a
  late-joiner / reconnecting replica (no live op ever stamped the fence), so the
  server delivery path is sound; the bug is purely the client fence collision.
  This scenario is **RED on main by design** and gated OFF the green exit code
  (reported as "known-red", not fatal) until plugin `#282` lands.

- **`TODO(headless)`: stale-head `#285` regression** — terminate_room via the
  backend_rpc HTTP seam, edit via REST, reconnect a replica, MUST converge (the
  `#285` e2e-equivalent, deterministic in minutes not dice). This is the tier's
  real headline payload. It needs the `#285` server fix in the image (unmerged
  PR `#1073`). Add once `#1073` merges (or base a follow-up on that branch).

## File map

| File | Role |
|---|---|
| `preload.ts` | `bun --preload`: aliases `obsidian` → the sim shim, shims `window`, installs `fake-indexeddb` (all sourced from `ENGRAM_PLUGIN_SRC`). |
| `barriers.ts` | `CatchupSignal` + `synced` / `noteVisible` / `serverHasContent` event barriers. |
| `run.ts` | REST setup (register + plan grant + api-key + vault), the headless `Replica` boot (main.ts wiring order), and the scenarios. |

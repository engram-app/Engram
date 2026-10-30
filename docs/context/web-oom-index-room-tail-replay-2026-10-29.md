# Context Doc: Prod web OOM crash loop from CRDT index room tail replay (2026-10-29)

_Last verified: 2026-10-30_

## Status
FIXED. Fix PR 2308 merged 2026-10-29 (`be1f66559`) and shipped in 0.69.0; issue 2306 is closed. Mechanism below describes the PRE-fix code (0.67.0 and 0.68.0).

## What This Is
Prod web tasks were OOM-killed (exit 137) 2-3 minutes after start, from 01:25Z to 01:47Z on 2026-10-29. BEAM binary memory went from about 20 MB to 700-1,130 MB while the process heap stayed flat. The worker tier was unaffected. Cause: the per-vault CRDT index room (`filemeta_v0`) replays its whole stored update tail when it binds, and an OOM kill means the tail is never folded, so every restart replays it again.

## Environment
SaaS prod, ECS web tasks (`role="web"`). Exposure exists in 0.67.0 and 0.68.0 alike.

## Mechanism (pre-fix, 0.67.0 and 0.68.0)
- The index room is one process per vault, registered `{:global, {:crdt_index, vault_id}}` (`lib/engram/notes/crdt_index_doc.ex`). It lives on exactly one node in the cluster.
- On bind, `CrdtIndexPersistence.bind/3` calls `replay_tail/3`, which calls `apply_echoing?/2` for every stored update (`lib/engram/notes/crdt_index_persistence.ex`; 0.68.0 crash logs pointed at lines 250, 577 and 618, which no longer match). It loads the whole tail with ONE `Repo.all` inside ONE long transaction and encodes the state vector twice per row. That is where the binary memory comes from.
- Why it grew quadratically: each roomless write (`fold_roomless/3`) minted a fresh Yjs client id, so the vault's state vector gained one entry per write, about 15k entries here. Two state-vector encodes per replayed row made the replay O(rows x client ids): the fix PR measured 1,917 MB at 15k rows vs 11 MB after the fix.
- The tail is only folded into a snapshot on a clean `unbind/3`. An OOM kill skips `unbind`, so the tail stays as large as before.
- Trigger: one user ran a bulk first sync of about 15.5k notes, which grew that vault's tail. The 0.68.0 deploy restarted the nodes, so the room re-bound and replayed. The task died, clients reconnected, the room re-bound on whichever node now hosted the global name (old or new version), and replayed the same tail again. Self-sustaining loop.

## Key Commands / Patterns (how to diagnose next time)
- CloudWatch Logs group `/ecs/engram-saas-prod`, stream `engram-engram-firelens-<task>`: grep for `replay_tail`. Crashed tasks logged `DBConnection ... checked out the connection for longer than 15000ms` at the replay lines.
- Pyroscope `{role="web"}`, group by function: `replay_tail` was 64% of web CPU from 01:20Z to 01:50Z.
- Prometheus `engram_prom_ex_beam_memory_binary_total_bytes` per `task` label: binary climbs to about 1 GB while heap is flat.
- After the fix: the `index_tail` metric (phases incl. `corrupt_row`) shows the tail size and fold activity; a tail that stays well above 500 rows means folds are failing.

## The fix (PR 2308, 0.69.0)
- Live fold: the tail is folded into the snapshot every 500 rows or 2 MB, by one long-lived background folder process per room (one fold in flight, later requests coalesced), under the advisory lock `crdt_index_fold:<vault>`.
- Paged replay through `IdWindows.reduce`, 1,000-row pages, applied in id order in one Yjs transaction.
- One stable server client id per vault for roomless writes, so the state vector no longer grows per write.
- Corrupt rows (`encoding_exception`) are deleted and counted as `index_tail{phase="corrupt_row"}`.
- Staging proof (comments on PR 2308): SIGKILL at 15k notes with a 475-row tail recovered at 184 MiB BEAM, no replay spike; tail peaked at 498 rows across a 15k-note bulk sync. A full 30k run is not yet proven.

## Failed Approaches / Dead Ends
- **Attachment upload bursts from the same user.** Looked causal (same user, same window). Ruled out: binary grew 1,050 MB in 15 s while socket input grew only 20.6 MB, and the spikes continued after that user's uploads were refused with 402.
- **Release 0.68.0.** Rolled back via engram-infra PR 1667; did not help. 0.67.0 has the same exposure, because the loop follows the global room, not the release.

## Gotchas
- Pre-fix, a restart did not clear this: the unfolded tail persisted in Postgres, so a fresh task replayed it again, and restarts kept the loop going. Post-fix, the tail is bounded by the live fold, so a restart replays at most about 500 rows.
- The global room can land on an old-version node, so "rolled back and still crashing" does not clear the new release, and "only new tasks crash" is not a signal either.
- Heap-flat plus binary-high points at large binaries held during encoding (state vectors, update rows), not a process-state leak.

## References
- `docs/context/crdt-index-room.md` (index room wire and projection)
- `docs/context/crdt-room-lifetime-and-drain.md` (room lifetime, drain)
- engram-app/Engram issue 2306 (incident), PR 2308 (fix)
- engram-app/engram-infra PR 1667 (0.68.0 rollback)

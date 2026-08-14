# CRDT room lifetime — why `auto_exit` is not enough, and why an idle room is DRAINED, not stopped

_Last verified: 2026-08-14_

**TL;DR:** A `SharedDoc` room only exits when its **last observer leaves** (`auto_exit`). That
bounds a *note* room, which is observed only while the note is open. It does **not** bound a
per-vault **index** room (#1150), which is observed for as long as any client is connected — so
its lifetime is session-length and residency scales with concurrent connections instead of
mutation rate.

The obvious fix — a timer that stops the idle room — **silently loses edits**, because a client
edit is a `GenServer.cast`. So an idle room instead **broadcasts a drain**, its observers let go,
and the `auto_exit` that already exists does the exiting.

Shipped: PR TBD (`feat/crdt-room-idle-exit`), opt-in via `idle_exit_ms`, default `nil`.
Refs: engram-app/Engram#1152, #1150, #1149, engram-app/engram-workspace#167.

---

## The trap: an edit is a cast, so a dead room eats it silently

`y_ex` dispatches inbound frames by type (`deps/y_ex/lib/server/doc_server_worker.ex:16-31`):

| frame | dispatch | what happens if the room is already dead |
|---|---|---|
| `MSG_QUERY_AWARENESS` `<<3>>` | `GenServer.call` | caller **exits** |
| `sync_step1` `<<0,0,…>>` | `GenServer.call` | caller **exits** (kills the channel) |
| **`sync_update` `<<0,2,…>>`** | **`GenServer.cast`** | **returns `:ok`, frame is dropped** |

A client edit is a `sync_update`. `crdt_channel.ex` already carries the warning at its room
monitor:

> Watch the room: if it dies (crash, node loss), evict it from the cache so the next crdt_msg
> re-creates it. Without this, send_yjs_message casts to a dead pid return `:ok` and every
> subsequent edit is silently dropped.

Today that only happens on a **crash**. A naive idle-exit would make it happen **on a timer, on
purpose** — and the eviction is driven by an asynchronous `:DOWN`, so there is a real window where
the channel's cached pid points at a corpse. That is silent user data loss, inside the very epic
(#167) whose purpose is eliminating silent drift.

**So #1152's literal wording — "a timer that exits with observers still attached" — is wrong, and
should not be implemented as written.**

## The inversion: make observers let go, and `auto_exit` does the rest

`SharedDoc.handle_call({:unobserve, …})` returns `{:reply, :ok, state, 0}`, and that `:timeout`
runs the same `observer_process === %{}` check as `:DOWN`
(`deps/y_ex/lib/protocols/shared_doc.ex:190-201`). So the last unobserve stops the room by itself —
no `GenServer.stop`, no fork of `y_ex`.

```
CrdtCheckpointTimer idle (no :activity for idle_exit_ms)
  └─ PubSub.broadcast(CrdtRegistry.drain_topic(note_id), {:crdt_room_drain, room_pid})
       └─ each CrdtChannel: evict assigns.rooms/room_doc  →  SharedDoc.unobserve(room)
            └─ LAST unobserve → auto_exit → terminate/2
                 └─ CrdtPersistence.unbind/3 → checkpoint (CheckpointGate, Oban overflow)
```

**Why this closes the race — message ordering, not luck.** The channel evicts its cached pid in
the *same* `handle_info` that unobserves, so relative to the drain message:

- a frame **ahead** of the drain in the channel's mailbox reached the room while it was still live
- a frame **behind** it finds no cached pid and re-resolves through `ensure_room` → fresh room

There is no interleaving where a frame casts at a dead pid. The one remaining race — a new
`ensure_started` colliding with the dying room's `:global` deregistration — is pre-existing and
already handled by `observe_with_retry` (`crdt_registry.ex:119-136`).

## Things that already existed (do not rebuild them)

Roughly half of #1152 turned out to be already-shipped machinery:

- **checkpoint-then-exit** — `terminate/2` calls `unbind/3`, which checkpoints. Nothing extra.
- **pool safety under a fleet-wide drain** — `CheckpointGate` caps inline checkpoints and overflows
  to the `crdt_checkpoint` Oban queue (the 2026-07-09 pool-exhaustion fix).
- **client re-spin** — `ensure_room` lazily recreates on the next frame. Built for crash/node-loss.
- **residency enumeration** (for the LRU backstop) — `DynamicSupervisor.which_children(CrdtDocSupervisor)`,
  already used by `DataCase.stop_crdt_rooms/0`.

## The announce amplification (the non-obvious one)

`start_and_observe_room` ends with `broadcast_from!(socket, "crdt_doc_ready", …)`, and its own
comment says recipients answer with a syncStep1. That is cheap today because a **re-spin only
happens on a crash or node loss**. The drain makes re-spin **routine**, so without care every
drain→edit cycle fans a handshake out of every other device on the vault — against `@hs_limit`
(`crdt_channel.ex:61`) and the plugin's 240/10s `crdt_msg` budget (Engram-obsidian#159). Handshake
starvation is the documented trigger for the wrong-mint cross-file overwrite class, so this is not
merely noisy.

Fix: the channel records doc_ids it released to a drain (`assigns.drained`) and skips the announce
on exactly that re-spin, consuming the mark so a *later* drain is suppressed independently. Scoped
to the drain path on purpose — a crash re-spin still announces, because there the peer state really
is unknown.

**There is a second announce source that masks this in tests.** `CrdtCheckpoint` announces
`crdt_doc_ready` on every content-*changing* checkpoint (`crdt_checkpoint.ex:213`, gated on
`prev_hash != new_hash`). So:

- draining a **clean** room (the ordinary index-room shape) announces nothing — compaction-only
  checkpoints hash-match and stay quiet;
- draining a **dirty** room announces once from the checkpoint, which is correct and pre-existing.

Consequence for testing: **re-spin with a syncStep1, never with an edit.** An edit produces its own
checkpoint announce, so the two sources become indistinguishable and a suppression test passes or
fails for the wrong reason. This cost a debugging cycle.

## Two things `auto_exit` gave us for free that a timer does not

**Spread.** `auto_exit` fires on user behaviour, so exits are naturally desynchronised. Idle timers
are armed when the room *starts*, so every room started in the same burst (a deploy, a reconnect
storm) drains in the same instant — a synchronized checkpoint storm, i.e. the 2026-07-09
pool-exhaustion shape. `CheckpointGate` + Oban would absorb it, but designing the spike in and
leaning on the shock absorber is backwards. Hence `jittered_drain_delay/1`, additive only:
`idle_exit_ms` is a floor (a minimum quiet period before a room may be taken away), so jitter must
never shorten it.

**A bound.** `auto_exit` needs no bookkeeping. The drain needs the channel to remember which
doc_ids it released (`assigns.drained`) so the re-spin stays quiet — and `@default_max_rooms` bounds
CONCURRENT rooms, not cumulative ones, while drain-churn is the intended steady state. Capped via
`remember_drained/3`, which CLEARS on overflow: the only degradation is lost suppression (a re-spin
announces, i.e. pre-drain behaviour), never incorrectness, so it needs no ordering bookkeeping.

## Observability

`[:engram, :crdt, :room_drain]`, `%{count: 1}`, `%{phase: :requested | :reasked | :released |
:skipped}` → `engram_prom_ex_crdt_room_drain_total` (`Engram.PromEx.Crdt`).

`released` should track `requested`. `requested` climbing while `released` stays flat means rooms
are being asked to drain and not going away — the unbounded-residency failure the drain exists to
prevent — and a rising `reasked` localises it to observers that cannot act. This is the only way to
answer #1152's "resident room count bounded under a soak" in production rather than in a test.

Cardinality contract: the four phase atoms and nothing else. Never note/vault/user ids — a room
drains repeatedly.

## Gotchas

- **PubSub, not a node-local registry.** Rooms are `:global`, so a room on this node may be
  observed by channels on any other node. `SharedDoc` also keeps `observer_process` private, so a
  room cannot message its own observers directly.
- **`unobserve` is a `GenServer.call` with no timeout knob.** A room that already exited would
  **exit the channel**; one that is alive but wedged would **stall it for y_ex's 5 s default**.
  `release_room/1` guards cheapest-first: dead → skip; doesn't answer a
  `update_doc/3` no-op probe within 1 s → skip; else unobserve. `catch :exit` backstops each gap.

  Skipping a wedged room loses nothing: `auto_exit` runs off the room's own observer bookkeeping,
  so a room too wedged to answer was never going to exit on that unobserve anyway — the timer's
  backed-off re-ask collects it when it recovers.

  The probe is `update_doc/3` specifically because it is **public API that takes a timeout**, where
  `unobserve/1` does not. Do NOT "fix" this by hand-rolling
  `GenServer.call(room, {:unobserve, self()}, …)`: that hard-codes y_ex's private message shape and
  would fail silently on a dep bump. Test it with plain non-replying processes for the same reason —
  a stub that answers `{:update_doc, …}`/`{:unobserve, …}` would bake those shapes into the suite.
- **Unsubscribe on the `:DOWN` path too.** `Phoenix.PubSub` does not dedupe subscriptions, so a
  room that dies by crash (evicted via `:DOWN`, never drained) leaves the subscription behind and
  the next `start_and_observe_room` stacks a second one — every later drain then arrives twice.
- **`Phoenix.PubSub.subscribe/2` returns `:ok | {:error, …}`** and dialyzer flags the unmatched
  return. Do not `_ =` it: a failed subscribe means that room can never be drained, i.e. exactly
  the unbounded-residency failure the drain exists to prevent. Log it.
- **The drain re-arms, with backoff.** An observer that ignores a drain (stale client, wedged
  channel) is asked again rather than pinning the room forever — but each unanswered ask lengthens
  the next (`drain_delay/1`, capped at 8x), so an observer that can *never* act cannot hold a fixed
  broadcast rate for the life of the room. Any `:activity` resets the count.
- **Gate the broadcast on observed idleness, not on the timer.** `Process.cancel_timer/1` cannot
  un-send a message already in the mailbox, so an `:idle_drain` queued just before an `:activity`
  is still handled after it. Re-arming alone does NOT give you "activity postpones the drain" —
  `idle?/2` re-checks the real clock. Without it, a room being actively typed into gets drained
  (lossless, since unbind checkpoints, but pure churn).
- **`idle_exit_ms: 0` is not falsy in Elixir.** It survives an `||` config fallback and would
  `send_after(…, 0)` in a tight broadcast loop. `arm_idle/1` is guarded on a positive integer so
  `nil`, `0`, and garbage all no-op.
- **Arm at `init`, not only on `:activity`.** The common index-room case is spin → handshake → go
  quiet with no writes at all; a drain armed only by activity would never fire for it.

## Testing notes

Both mailbox orderings are pinned in `test/engram_web/channels/crdt_channel_drain_test.exs`. Send
**both** the `push/3` and the drain **from the test process** — Erlang guarantees FIFO only per
sender/receiver pair, so driving the drain through PubSub instead makes the interleaving a genuine
race and the test a flake.

Assert on **materialization**, not on internal state: if a frame is cast into a corpse, no room
ever applies it and nothing reaches the row, whichever checkpoint path runs.

In `test/engram/notes/crdt_room_idle_exit_test.exs`, park `settle_ms`/`ceiling_ms`/`eager_ms` at
600_000 first. Otherwise the eager 250 ms flush materializes the content anyway and the
"checkpoints on exit" assertion passes vacuously.

## Constraints this puts on #1150 (read before enabling the drain)

- **The drain only bounds rooms that HAVE observers.** A room with zero observers never
  `auto_exit`s (no `:DOWN` fires, and `init` schedules no `:timeout`) and a drain does nothing for
  it either — there is nobody to ask. `crdt_transport.ex:158` already names the class:
  *"ensure_started has no observer and never reaps, leaking an immortal [room]."* So the index room
  must always go through `ensure_observed`, never `ensure_started` alone, or the memory work is
  defeated by construction.
- **`idle_exit_ms` is a memory-vs-latency knob, not a free win.** A re-spin runs `bind` → tail-log
  replay, and #1149 puts the index doc at ~2 MB encoded per 10k notes. Drain more eagerly than the
  typical inter-mutation gap and you pay that rehydration on every burst.
- **The client half is unverified here.** #1146 requires the client to reconcile against the CRDT,
  not a projection. Everything above assumes the client re-handshakes on the next mutation rather
  than falling back to the manifest; proving that is Engram-obsidian#362/#363.

## Cross-node coverage is a hole (not specific to this work)

`Process.alive?/1` is local-only and raises `ArgumentError` — `:error` class, so a `catch :exit`
does NOT contain it — on a remote pid. Rooms are `:global`, so channels routinely hold remote room
pids. An unguarded `alive?` here crashed the channel on every drain of a remote room.

It was not caught by the suite because **cluster tests never run**: `CLUSTER_TESTS=1` appears
nowhere in CI or the Makefile, and only `dek_cache_test.exs` carries `@tag :cluster`. The whole
cross-node surface — the `:distributed_ets` rate limiter, PubSub cache eviction, and this drain —
is CI-invisible. Assume any single-node-tested primitive is unproven across nodes until someone
wires that env var into a job.

## What this does NOT prove

The mechanism is proven (exit with observers attached, checkpoint on exit, correct re-spin under
both orderings, multi-observer release). The **load model is not**: #1149's 7.91 MB-per-10k-note
figure belongs to an index doc that does not exist until #1150, so nothing here validates the
absolute memory bound — only that residency is bounded at all. The resident-room LRU backstop
(#1152's third bullet) is also still outstanding.

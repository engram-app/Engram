# CRDT room lifetime — why `auto_exit` is not enough, and why an idle room is DRAINED, not stopped

_Last verified: 2026-08-15. **SUPERSEDED IN PART 2026-08-18/23, see update below — do not trust
this doc's "prod today" claims below without reading the update first.**_

> **Update 2026-08-24:** the "Only drain-ENABLED rooms are tracked... prod today, where nothing
> sets `idle_exit_ms`" claim below (and the identical claim in "Constraints this puts on #1150")
> is **no longer true**. PR #1413 (`perf(sync): fix the CPU + room-residency causes of the
> bulk-upload incident`, merged 2026-08-18, same day as the 757→2744-process incident this doc
> already describes) flipped `CrdtCheckpointTimer`'s `idle_exit_ms` default from `nil` (opt-in,
> armed only in CI) to **`@default_idle_exit_ms` = 300_000 ms (5 min), ON by default in every
> environment** — see the "Idle drain" section of that module's moduledoc, which now says
> outright: *"It used to be opt-in and nil by default... A residency bound that defaults off is
> unbound in exactly the fleets that need it most."* Deployed to prod via `release-v0.19.0`
> (tag `4a3b8bfc`, engram-infra#1041, 2026-08-23T09:26 UTC) — confirmed live: prod
> `engram_prom_ex_beam_stats_process_count` has held flat (~745-760 per task) for the following
> day with no runaway growth, and `engram_prom_ex_crdt_room_drain_total` shows real drain activity
> (~73 `requested` + ~35 `lru_evicted` per day against ~119/day `room_start{source="handshake"}` —
> roughly balanced, not accumulating). Rooms DO now auto-close in prod. The mechanism described
> below (drain-then-`auto_exit`, never a hard kill) is otherwise unchanged and still accurate —
> only the "off by default in prod" framing is stale. `CRDT_IDLE_EXIT_MS` (`ci/compose.yml`) still
> separately overrides the window for CI/e2e and is CI-gated (silent no-op in a real task
> definition) — that part of this doc is still correct.

**TL;DR:** A `SharedDoc` room only exits when its **last observer leaves** (`auto_exit`). That
bounds a *note* room, which is observed only while the note is open. It does **not** bound a
per-vault **index** room (#1150), which is observed for as long as any client is connected — so
its lifetime is session-length and residency scales with concurrent connections instead of
mutation rate.

The obvious fix — a timer that stops the idle room — **silently loses edits**, because a client
edit is a `GenServer.cast`. So an idle room instead **broadcasts a drain**, its observers let go,
and the `auto_exit` that already exists does the exiting.

Shipped: PR #1382 (`feat/crdt-room-idle-exit`), opt-in via `idle_exit_ms`, default `nil`.
Hardened by the review pass on PR #1383 — see "What the review caught" at the end.
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
  └─ PubSub.broadcast(CrdtRegistry.drain_topic(vault_id), {:crdt_room_drain, room_pid})
       └─ each CrdtChannel: SharedDoc.unobserve(room)  →  evict assigns.rooms/room_doc
            └─ LAST unobserve → auto_exit → terminate/2
                 └─ CrdtPersistence.unbind/3 → checkpoint (CheckpointGate, Oban overflow)
```

**Why this closes the race — message ordering, not luck.** The channel releases and evicts inside
the *same* `handle_info`, which is atomic with respect to its own mailbox, so relative to the drain
message:

- a frame **ahead** of the drain in the channel's mailbox reached the room while it was still live
- a frame **behind** it finds no cached pid and re-resolves through `ensure_room` → fresh room

There is no interleaving where a frame casts at a dead pid. Note the ORDER inside the callback is
therefore free — nothing else runs between the two — which is what lets the release go first and
report whether it actually succeeded. (An earlier version evicted first and released blind; see
"What the review caught".) The one remaining race — a new
`ensure_started` colliding with the dying room's `:global` deregistration — is pre-existing and
already handled by `observe_with_retry` (`crdt_registry.ex:138-158`).

## Things that already existed (do not rebuild them)

Roughly half of #1152 turned out to be already-shipped machinery:

- **checkpoint-then-exit** — `terminate/2` calls `unbind/3`, which checkpoints. Nothing extra.
- **pool safety under a fleet-wide drain** — `CheckpointGate` caps inline checkpoints and overflows
  to the `crdt_checkpoint` Oban queue (the 2026-07-09 pool-exhaustion fix).
- **client re-spin** — `ensure_room` lazily recreates on the next frame. Built for crash/node-loss.
- **residency enumeration** (for the LRU backstop) — `DynamicSupervisor.which_children(CrdtDocSupervisor)`,
  already used by `DataCase.stop_crdt_rooms/0`. The shipped LRU does NOT use it: eviction needs a
  `last_activity` per room to order by, which `which_children` cannot supply. It uses its own ETS
  table instead (below). Do not "simplify" it back onto `which_children` — that silently loses the
  ordering the whole policy is built on.

## The announce amplification (the non-obvious one)

`start_and_observe_room` ends with `broadcast_from!(socket, "crdt_doc_ready", …)`, and its own
comment says recipients answer with a syncStep1. That is cheap today because a **re-spin only
happens on a crash or node loss**. The drain makes re-spin **routine**, so without care every
drain→edit cycle fans a handshake out of every other device on the vault — against `@hs_limit`
(`crdt_channel.ex:74`) and the plugin's 240/10s `crdt_msg` budget (Engram-obsidian#159). Handshake
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

## The LRU backstop

Idle-exit bounds rooms that go **quiet**. It does nothing for a continuously-active room, so a
pathological mix of busy vaults still pins memory. `Engram.Notes.CrdtRoomLru` is the pressure valve:
a named public ETS table (`{note_id, room_pid, vault_id, last_activity}`, mirroring `FanoutPacer`)
plus a
periodic sweep that prunes dead entries and then drains down to `max_resident`.

Three properties worth keeping:

- **It drains, it never kills.** Eviction broadcasts on the room's drain topic exactly as the idle
  timer does. Killing would silently eat the next `sync_update`, which is the whole reason the drain
  exists.
- **It deliberately bypasses `idle?/2`.** Evicting rooms that are *not* idle is its entire job —
  which is precisely why it must go through the safe release path instead of inventing a second one.
- **Prune before selecting.** A room that exited between sweeps still holds an entry; counting
  corpses toward residency evicts healthy rooms to free memory nothing is using.

Only drain-ENABLED rooms are tracked (`touch/3` is called from the timer only when `idle_exit_ms`
is a positive integer — the same guard `arm_idle/1` uses, so `0` means disabled to both), so where
the drain is off nothing can be LRU-evicted either. That is **prod today**, where nothing sets
`idle_exit_ms`. It is NOT CI/e2e: `CRDT_IDLE_EXIT_MS` in `ci/compose.yml` turns the drain on
fleet-wide for every note room, which is the point — the whole Obsidian suite then exercises it
against the real client.

Note the unblocking event is **#1151, not #1150**. #1150's index room deliberately does not opt in,
because it has no persistence yet; see `crdt-index-room.md`.

Every tracked pid is local — a room's timer runs on the room's node — so `Process.alive?/1` is safe
here, unlike in the channel. `touch/3` and `forget/1` also no-op while the table is missing: the
table is owned by the LRU GenServer, and a bare `:ets` call would raise in the CALLER, which is a
checkpoint timer linked to a room that does not trap exits — the room would die by signal and skip
its unbind checkpoint. A memory backstop must never cost a room its checkpoint.

`max_resident` defaults to 64 and wants tuning against real index-doc sizes once #1150 exists;
#1146's arithmetic says ~128 resident rooms would consume an entire task.

## Residency is a property of the TRANSPORT, not of handshakes (#1493)

The natural reading of a room-count problem is "too many handshakes." That is the wrong shape and
it costs a day if you chase it.

`crdt_msg` routes **every** frame through `ensure_room` (`crdt_channel.ex:234`) — a syncStep1, a
STEP2, and a plain `sync_update` for a note nobody has open, all of them. So a room is not what you
get for *asking to handshake*; it is what you get for *sending anything at all* about a note. On
2026-08-28 a 1.4k-note sync put residency at **314 against a cap of 64**, and the top contributor
was the plugin's durable op-queue drain (`sync.ts fireCrdtReHandshake`) — which cannot be gated,
because it is the delivery path for idle notes' queued edits and skipping it loses them.

Two things follow, and both are non-obvious enough to be worth writing down:

**1. The lifetime knob is WHO OBSERVES, not whether a room starts.** `CrdtRegistry.ensure_observed`
binds a room's lifetime to the calling process (`auto_exit` fires on last-unobserve). Call it from
the channel and the room lives as long as the socket. Call it from a short-lived task and the room
checkpoints and exits the moment the task does — or stays untouched if a live editor is also
observing it. Same room, same apply, same fan-out; residency goes from O(notes pushed) to
O(applies in flight). That is the whole of `crdt_doc_update`'s mechanism.

Do **not** "fix" this by calling `ensure_started` without an observer. A room with no observer
never trips `auto_exit` and falls back on the idle drain alone — worse than what you started with.
For the same reason `crdt_doc_update` does not `Task.shutdown` its applier on timeout: killing it
between `ensure_started` and `observe` lands in exactly that state. It disowns the task instead.

**2. A room-free frame must still bill the handshake lane.** `crdt_doc_state` and `crdt_doc_update`
both stand in for a handshake, so putting them on the edit lane would let a bulk vault sync starve
the user's real typing — the 2026-07-07 cross-file-overwrite incident shape. Both use
`state_frame_class/1` (a size gate: small rides `:handshake`, oversized pays `:edit`), which
`crdt_create`'s genesis seed introduced.

**What this does NOT do:** it does not make `@max_evictions_per_sweep` right. That cap is still a
fixed batch with no feedback term, deliberately, because each eviction costs the owning channel a
serial ~1s probe. Its comment scopes the trade to "stops mattering once a bulk upload no longer
creates a room per note (#1409)" — a precondition that was assumed met from 2026-08-26 and was
still false in the field on 2026-08-28. Re-read it only once #1493's two PRs are **in a release**,
not when they merge.

## Observability

`[:engram, :crdt, :room_drain]`, `%{count: 1}`, `%{phase: :requested | :reasked |
:request_failed | :released | :skipped_dead | :skipped_unresponsive | :lru_evicted}` →
`engram_prom_ex_crdt_room_drain_total` (`Engram.PromEx.Crdt`).

**Do not alert on `released` vs `requested`.** An earlier version of this doc said `released`
should track `requested`; it cannot. A request is emitted ONCE PER ROOM (one broadcast), a release
once per OBSERVING CHANNEL — so a healthy 3-device vault runs at roughly `3x released` per
`requested`, and the multiplier is unknowable from the metric (`observer_process` is private, which
is why the drain is a broadcast at all). Worse, a genuine leak can sit at exactly 1:1.

Alert on the phases that mean one thing each:

- `skipped_unresponsive` — a room that is ALIVE but did not answer the probe, so it still holds an
  observer it cannot shed. Should be ~zero; any sustained rate is the unbounded-residency failure.
- `reasked` — same problem, seen from the timer's side.
- `request_failed` — the broadcast itself errored, so nothing was asked.
- `lru_evicted` — should be ~zero; sustained means idle-exit alone is not keeping up.
- `skipped_dead` — routine, rooms die on their own.

Cardinality contract: the phase atoms listed above and nothing else. Never note/vault/user ids — a
room drains repeatedly.

## Gotchas

- **PubSub, not a node-local registry.** Rooms are `:global`, so a room on this node may be
  observed by channels on any other node. `SharedDoc` also keeps `observer_process` private, so a
  room cannot message its own observers directly.
- **The drain topic is PER VAULT, not per note — this is a memory decision, not a style one.**
  Per-note meant one subscription per room OPEN, and the enroll-everything client opens a room per
  note. Measured 2026-08-14: **309 bytes per subscription**, so ~725 KB per socket on a 2400-note
  vault and **~707 MB per 1000 such clients** — against the same 1024 MB task whose memory this
  feature exists to protect. Self-defeating at the scale #1146 targets, and invisible to every
  correctness check: CI was fully green with the per-note version.
  Per-vault needs no extra routing, because the drain carries the room pid and
  `handle_info({:crdt_room_drain, room}, …)` already no-ops on a pid the channel does not hold.
  `crdt_channel_drain_test.exs` pins it by COUNTING subscriptions while opening many rooms.
- **`unobserve` is a `GenServer.call` with no timeout knob.** A room that already exited would
  **exit the channel**; one that is alive but wedged would **stall it for y_ex's 5 s default**.
  `release_room/1` guards cheapest-first: dead → skip; doesn't answer a
  `update_doc/3` no-op probe within `@room_probe_ms` (1 s, overridable via `:crdt_room_probe_ms`,
  which the drain tests use) → skip; else unobserve. `catch :exit` backstops each gap.

  **A skip is not a release, and the caller must not treat it as one.** `release_room/1` returns
  `:gone` (released, or already dead) or `:retry` (alive but wedged). On `:retry` the channel KEEPS
  its cached pid: it is still in the room's `observer_process` map, so `auto_exit` can never fire
  until a later re-ask succeeds, and a channel that had forgotten the pid would answer every re-ask
  with "not ours" — pinning the room for the life of the socket. Evicting unconditionally was the
  original shape and it turned this feature into the leak it exists to prevent.

  Skipping a wedged room loses nothing: `auto_exit` runs off the room's own observer bookkeeping,
  so a room too wedged to answer was never going to exit on that unobserve anyway — the timer's
  backed-off re-ask collects it when it recovers.

  The probe is `update_doc/3` specifically because it is **public API that takes a timeout**, where
  `unobserve/1` does not. Do NOT "fix" this by hand-rolling
  `GenServer.call(room, {:unobserve, self()}, …)`: that hard-codes y_ex's private message shape and
  would fail silently on a dep bump. Test it with plain non-replying processes for the same reason —
  a stub that answers `{:update_doc, …}`/`{:unobserve, …}` would bake those shapes into the suite.
- **Never unsubscribe on room teardown.** There is exactly ONE subscription per connection, taken
  at `join/3`, and it covers every room the channel will ever hold. Dropping it when a single room
  drains or dies (`:DOWN`) would go unnoticed by any test — that channel would simply stop
  answering drains for the rest of the session, and its rooms would pin memory forever. The
  per-room subscribe/unsubscribe pair this replaced existed only because the topic used to be
  per-note; see the memory decision above. `Phoenix.PubSub` also does not dedupe, so re-subscribing
  "just in case" stacks duplicates and every later drain arrives twice.
- **`Phoenix.PubSub.subscribe/2` returns `:ok | {:error, …}`** and dialyzer flags the unmatched
  return. Do not `_ =` it: a failed subscribe means that room can never be drained, i.e. exactly
  the unbounded-residency failure the drain exists to prevent.

  The channel takes the stricter route and hard-matches `:ok = Phoenix.PubSub.subscribe(…)`, so a
  failed subscribe raises in `join/3` and the connection fails loudly rather than connecting into a
  state where its rooms can never drain. Either is defensible; silence is not.
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
is CI-invisible. Assume any single-node-tested primitive is unproven across nodes.

**Whether `CLUSTER_TESTS=1` can go on the existing `unit-tests` job is UNRESOLVED — and an earlier
version of this doc got it wrong.** That version claimed a controlled comparison proved distribution
contaminates the main suite: without the flag 4368 tests / 0 failures, with it 4371 / 1 failure in
`FanoutPacerTest`. The mechanism sounded right (`ClusterCase.start_peer!` starts a second
`Phoenix.PubSub` under the same `Engram.PubSub` name on the peer and connects the nodes, so the pg
group spans both and a 200 ms pacing assertion would not survive the cross-node fan-out).

**It was one observation, and `FanoutPacerTest` is load-flaky on its own.** Measured 2026-08-15 on
plain `main`, no cluster tests anywhere: **4/6 failures under CPU contention**, plus an unrelated
full-suite failure of the same test. So the single cluster-run failure cannot be attributed to
distribution — the experiment proves nothing either way.

Lesson worth keeping: a plausible mechanism plus one failing run is not a finding. Establish the
test's own flake rate FIRST, or the baseline is unknown and any comparison against it is noise.

What IS known: `CLUSTER_TESTS=1 mix test --only cluster` is green 5/5 in isolation, so a separate
job is a safe shape regardless. Whether the simpler in-job approach works needs re-running on a
quiet machine (or in CI) with the flake rate characterised first.

## Timing-sensitive tests on this suite (measured 2026-08-15)

Two tests fail under CPU contention independently of any change — budget for this when reading a
single red run, and characterise the flake rate before attributing a failure to a diff:

| test | shape | observed |
|---|---|---|
| `FanoutPacerTest` | 200 ms pacing assertions | 4/6 under load |
| `Engram.Vector.QdrantHybridTest` | `async: true` + Bypass HTTP + `Req` timeout (one of 47 Bypass tests) | 1 full-suite run, not reproducible in isolation |

Returning to the cross-node coverage hole above: because of it, the remote-pid guard is ALSO
covered by a single-node test that injects the
"self" node (`locally_dead?/2`) rather than faking a remote pid — so the guard is gated by the
default suite even though the `:cluster` test is not.

## What this does NOT prove

The mechanism is proven (exit with observers attached, checkpoint on exit, correct re-spin under
both orderings, multi-observer release). The **load model is not**: #1149's 7.91 MB-per-10k-note
figure belongs to an index doc that does not exist until #1150, so nothing here validates the
absolute memory bound — only that residency is bounded at all.

The resident-room LRU backstop (#1152's third bullet) shipped in the same PR — see "The LRU
backstop" above.

## What the review caught (2026-08-15)

#1382 merged green — full suite, credo, dialyzer, and the whole Obsidian e2e suite with the drain
and LRU enabled via `ci/compose.yml`. An independent multi-agent review of the merged code then
found six real defects. Worth recording *why* CI could not have found them:

| defect | why no test could fail |
|---|---|
| A skipped release still evicted the cached pid, so the room kept an observer it could never shed and every re-ask no-op'd | The room stays alive and healthy. Nothing is lost, nothing errors — the only symptom is memory that never comes back, over a timescale no test runs for. |
| `:skipped` conflated "already dead" (routine) with "alive but wedged" (a leak) | A counter that is merely *ambiguous* still increments. You need an operator asking a question the metric cannot answer. |
| `released` vs `requested` was documented as a 1:1 invariant; it is 1:N over the observer count | Every test has exactly one observer, so 1:N and 1:1 are indistinguishable in the suite by construction. |
| The re-spin announce was suppressed for `.canvas` too, but its backstop is `.md`-gated | Two *different* files, each correct in isolation. Only reading them together shows the gap. |
| The LRU counted an ask as an eviction and let one stuck room monopolise every sweep | Needs a room that ignores the drain AND a second sweep. The tests asserted the first sweep's broadcast, which is right up to the point where it isn't. |
| `touch/3` raised into a linked checkpoint timer if the LRU restarted, killing the room's checkpoint | Requires the LRU GenServer to crash, which nothing makes it do. |

The pattern: **CI proves the mechanism, not the model.** Every one of these is a statement about
what happens over time, across processes, or between two files — none of which a green suite
speaks to. The 707 MB per-note-topic defect earlier in this same feature was the same shape, and
also shipped fully green.

Each fix landed with a regression test that was **mutation-tested**: the fix was reverted and the
new test confirmed red, then restored. Treat any test in this area that passes on first write with
suspicion.

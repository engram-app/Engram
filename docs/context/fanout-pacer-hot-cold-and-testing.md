# Context Doc: FanoutPacer — hot/cold classification and how to test it

_Last verified: 2026-08-03_

## Status

Working. Pacing is ON by default in prod (`Engram.Notes.FanoutPacer`, shipped
#1002 / #1003). Ops-hardening follow-ups are tracked in
[#1004](https://github.com/engram-app/Engram/issues/1004) and are **not done** —
notably there is still no telemetry gauge for cold-queue depth, so a backing-up
queue is invisible in prod.

## What This Is

The vault-channel fan-out pacer classifies every frame HOT or COLD and treats
them differently, which is the source of both its value and its testing traps.

- **HOT** — the note had a fan-out within `fanout_hot_window_ms`. Someone is
  actively editing it, so the frame broadcasts **inline** and never enters the
  GenServer. This is the latency-critical path.
- **COLD** — not seen recently. The frame is enqueued and drained in batches of
  `fanout_drain_batch` every `fanout_drain_interval_ms`, so a genesis flood of a
  large vault cannot flood the channel.

## The short-circuit trap (bit us in PR #1218)

`emit/4` is written as:

```elixir
if pacing_enabled?() and cold?(note_id) do
```

`cold?/1` is what **writes the ETS hot-mark** — it records "note seen now" as a
side effect of classifying. Because `and` short-circuits, disabling pacing means
`cold?/1` is *never called*, so nothing is ever marked seen.

**Consequence for tests:** you cannot warm a note to HOT via the inline path. A
test that flips `:fanout_pacing_enabled` to `false`, emits, then flips it back
expecting a HOT note gets a **COLD** one, and any "hot frame bypasses" assertion
built on it is either failing or, worse, passing for the wrong reason. Warming a
note to HOT necessarily goes through the paced path, and that first frame is by
definition cold — so it will be queued and delivered on a drain tick.

## Testing the pacer without flaking

A drain tick is load-variable work. Never put one inside a timed
`assert_receive`: under full-suite load (`max_cases: 20`) it drifts past a tight
window and the test fails on its *setup*, not on the property it exists to prove.
That was the `#1002` bypass test's flake — the failing assert was the warm-up.

**Pattern that works** — keep the warm-up out of the mailbox entirely rather than
widening a timeout:

```elixir
# Emit BEFORE subscribing: broadcast to nobody, mailbox stays clean.
FanoutPacer.emit(topic, "note_yjs_update", payload("live"), "live")
await_drained(topic)
EngramWeb.Endpoint.subscribe(topic)
```

`await_drained/1` polls a **condition**, not a guessed sleep:

```elixir
not Map.has_key?(:sys.get_state(FanoutPacer).queues, topic)
```

This is sound because `handle_info(:drain)` calls `Broadcast.emit` synchronously
in `drain_topic/3` and only then rebuilds its queue map with emptied topics
rejected. So an absent topic key proves those frames are already broadcast.

Verify such a test by **mutation**, since a timing test going green proves very
little: delete the `:ets.insert` hot-mark in `cold?/1` so nothing can ever become
HOT, and confirm the bypass assert fails. (Avoid mutating the `and` expression
itself — `cold?(note_id) || true` trips warnings-as-errors and never compiles.)

## Gotchas

- `FanoutPacer.reset/0` clears the hot ETS table as well as the queues, so it
  cannot be used to drain a warm-up frame while keeping a note HOT.
- The test module is `async: false` on purpose — it shares the named process,
  global ETS, and application env.
- Config is read at **call time** (`Application.get_env` per emit/tick), not
  cached at boot. That is what makes `FANOUT_PACING_ENABLED` an instant rollback
  lever with no restart, and it is why tests can flip knobs mid-run.

## Rollback lever

`FANOUT_PACING_ENABLED=false` falls back to unpaced inline broadcast for every
note. Kept deliberately (PR #1217) even though it is unset in every deploy:
[#1004](https://github.com/engram-app/Engram/issues/1004) asks for a documented
config path rather than a per-node remote-console `Application.put_env`, and
until its cold-queue depth gauge lands we are blind to the queue backing up —
which makes the lever worth more, not less.

## References

- `lib/engram/notes/fanout_pacer.ex` — `emit/4`, `cold?/1`, `handle_info(:drain)`
- `test/engram/notes/fanout_pacer_test.exs` — `await_drained/2`
- PRs #1002 / #1003 (pacer), #1217 (flag kept + documented), #1218 (flake fix)
- Issue #1004 — ops hardening (telemetry gauge, bounded-queue alarm)
- `docs/context/environment-variables.md` — the knob table

# Context Doc: the headless tier must mirror main.ts's CRDT lifecycle

_Last verified: 2026-10-03_

## What this is

`e2e/headless/run.ts` boots the **real plugin SyncEngine** in Node against a real
backend, with no Obsidian. To do that it hand-rolls the wiring that
`plugin/src/main.ts` normally performs — which is why nearly every line in
`Replica.boot` carries a `// main.ts:NNNN` comment. That mirroring is a
**standing contract**: any lifecycle call added to main.ts's CRDT wiring has to be
added here too, or the tier silently tests a differently-wired stack.

## Example: the missing `setConnected` edges (#1120)

The plugin rebuild (#331) added a `setConnected` lifecycle to the provider
registry. The harness picked up none of its edges, so `connected` stayed
`false` for the whole run. The send path gates on it:

```ts
// note-provider.ts
private broadcast(frame: string): void {
    const sent = this.connected && this.send(frame);
    if (sent) return;
    this.buffer.push(frame);          // buffers forever if never connected
}
```

`ProviderRegistry.flushHeldState` gates on the same flag; the receive path
does not. Result:

```
[headless] PASS  handshake: A+B join + complete catch-up  (134ms)
[headless] FAIL  create -> server persists content        (120068ms)
        serverHasContent timeout: Headless/Persist.md expected 8236df98cd86
                                  got hash e3b0c44298fc after 120000ms
```

Handshake and catch-up (server→client) go green while every push (client→server)
times out. `e3b0c44298fc…` is the SHA-256 of the **empty string** — the note row
was created, the body never arrived. If you see that hash in a `serverHasContent`
timeout, read it as "nothing was ever sent", not "the wrong thing was sent".

## The three edges

| Event | Call |
|---|---|
| `onCrdtJoined` | `crdtManager.setConnected(true)` |
| `onCrdtJoinError` | `crdtManager.setConnected(false)`, `indexRoom.setConnected(false)` |
| `onStatusChange(false)` | `crdtManager.setConnected(false)`, `indexRoom.setConnected(false)` |

The harness mirrors the `crdtManager` calls but not `indexRoom` (it has no
index room). Harmless while the index-room wire ships OFF; add it when that
wire turns on.

The offline edge matters for the reconnect scenarios: `goOffline()` only drops the
channel, so without it the registry still believes it can send.

## Gotchas

- **This was harness-only.** The shipped plugin routes through main.ts, which has
  always made these calls. A red headless tier here did NOT mean a broken product
  — but it did mean the tier was not testing the product's real wiring.
- The tier is deterministic (event barriers, no wall clock), though still
  report-only while it bakes (see `testing-architecture-migration.md`). A 3/3
  failure in it is never a flake; do not rerun it hoping for green.
- When adding CRDT lifecycle wiring to main.ts, add the mirror to
  `e2e/headless/run.ts` in the same commit. Find the spot by handler name
  (`onCrdtJoined`, `onStatusChange`, ...), not by the `// main.ts:NNNN`
  anchors: those line numbers have drifted (e.g. `main.ts:2052` is now ~2861).

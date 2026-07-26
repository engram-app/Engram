# Context Doc: the headless tier must mirror main.ts's CRDT lifecycle

_Last verified: 2026-07-26_

## Status
Fixed (commit `6a7c3a23`, PR #1120). The headless tier went from 3 deterministic
failures back to green.

## What this is

`e2e/headless/run.ts` boots the **real plugin SyncEngine** in Node against a real
backend, with no Obsidian. To do that it hand-rolls the wiring that
`plugin/src/main.ts` normally performs — which is why nearly every line in
`Replica.boot` carries a `// main.ts:NNNN` comment. That mirroring is a
**standing contract**: any lifecycle call added to main.ts's CRDT wiring has to be
added here too, or the tier silently tests a differently-wired stack.

## The failure it caused

The persistent-doc rewrite (plugin #331) added a `setConnected` lifecycle to the
provider registry. main.ts calls it on three edges; the harness picked up none of
them. The registry's `connected` therefore stayed `false` for the entire run.

That matters because the send path gates on it:

```ts
// note-provider.ts
private broadcast(frame: string): void {
    const sent = this.connected && this.send(frame);
    if (sent) return;
    this.buffer.push(frame);          // buffers forever if never connected
}
```

`ProviderRegistry.flushHeldState` is gated on the same flag, so the create-ack
flush never fired either.

**The receive path does not consult that flag.** That produced a genuinely
misleading shape:

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

| Event | Call | main.ts |
|---|---|---|
| `onCrdtJoined` | `manager.setConnected(true)` | 2052 |
| `onCrdtJoinError` | `manager.setConnected(false)` | 2087 |
| `onStatusChange(false)` | `manager.setConnected(false)` | 1859 |

The offline edge matters for the reconnect scenarios: `goOffline()` only drops the
channel, so without it the registry still believes it can send.

## Gotchas

- **This was harness-only.** The shipped plugin routes through main.ts, which has
  always made these calls. A red headless tier here did NOT mean a broken product
  — but it did mean the tier was not testing the product's real wiring.
- The tier is the *deterministic* gate (see `testing-architecture-migration.md`).
  A 3/3 failure in it is never a flake; do not rerun it hoping for green.
- When adding CRDT lifecycle wiring to main.ts, grep `e2e/headless/run.ts` for the
  nearest `// main.ts:NNNN` anchor and add the mirror in the same commit.

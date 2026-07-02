# y-indexeddb `whenSynced` never resolves after `destroy()`

**Trigger:** Any code that awaits `IndexeddbPersistence.whenSynced` (directly or
via a cached promise) while `destroy()` can race the initial IndexedDB load will
hang forever. This is a property of the library, not a usage mistake.

## The library bug

y-indexeddb 9.0.12 emits the `synced` event from a callback that runs only after
the IDB transaction completes (dist/y-indexeddb.cjs ~line 93). If `destroy()` runs
first, the transaction is aborted and the `synced` event is never emitted.
`whenSynced` is a `Promise` that resolves on `synced` — so once `destroy()` races
ahead, it never settles. Any awaiter suspends permanently, leaking the promise, its
closures, and the destroyed `Y.Doc`.

## Where it bit us (PR #871)

`frontend/src/crdt/manager.ts` `entry()` cached a `ready` promise backed by
`persistence.whenSynced`. On fast note-switch, `closeDoc()` could be called while
a note was still mid-load:

1. `closeDoc` called `doc.destroy()` then `persistence.destroy()`.
2. The in-progress `entry()` was awaiting `ready` (= `whenSynced`), which now
   never resolved.
3. Every caller that had already called `entry()` — `getDoc`, `applyRemoteUpdate`,
   `encodeStateVector`, `handleFrame`, `startSync` — suspended permanently.
4. Post-await liveness guards (`hasDoc`, epoch checks) written for exactly this
   race were unreachable dead code.

Found only during the final whole-branch review of PR #871. Per-task reviews and
unit tests missed it because tests stubbed `getDoc` with manually-resolved
promises, hiding the hang at the `entry()` level.

## Fix (now in `manager.ts`)

Race `whenSynced` against a `destroy` signal so the promise ALWAYS resolves:

```ts
// y-indexeddb (9.0.12) never fires `synced` once destroy() runs, so a
// bare whenSynced would hang every awaiter if the doc is closed mid-load.
// Race it against the doc's "destroy" event (closeDoc/destroy call
// doc.destroy() before persistence.destroy()) so awaiters ALWAYS resume.
const destroyed = new Promise<void>((resolve) => doc.on("destroy", () => resolve()));
const ready: Promise<void> = Promise.race([
    persistence.whenSynced.then(() => undefined),
    destroyed,
]);
```

Awaiters always resume. Post-await liveness guards (`hasDoc`, epoch checks) then
do their job — the resumed value may be a destroyed doc, so the guard is mandatory.

**Corollary rule:** every awaiter of a doc-load promise must re-check liveness
after the await. A resolved promise is not a live doc.

## Testing note

Reproduce with the real `CrdtManager` over `fake-indexeddb` as the existing tests
do (`manager.test.ts`). Do not stub `getDoc` — stubs bypass `entry()` entirely and
hide the hang. The test must call `closeDoc` while an `entry()` is in flight to
trigger the race.

# Context Doc: Parallelising channel work against the DB pool

_Last verified: 2026-08-02_

## Status

Working — the create-batch path was fixed in PR #1194. The failure mode described
here is general to any Phoenix channel handler that fans work out with
`Task.async_stream`, so read this BEFORE adding parallelism to a channel.

## What This Is

Two coupled traps hit when `EngramWeb.CrdtChannel`'s `crdt_create_batch` was
changed from a serial `Enum.map_reduce` to `Task.async_stream`. Together they
turn one transient DB slowdown into a dead WebSocket topic that the client
retries against until it reconnects.

## The two traps

### 1. Concurrency sized off the CPU, not the contended resource

`max_concurrency: System.schedulers_online()` is the reflex default, and it is
right when the work is CPU-bound. It is wrong here: every batch entry opens its
own `Repo.with_tenant` **transaction** (see `lib/engram/repo.ex`), which checks
out a pooled connection and holds it for the entry's whole duration. N
concurrent entries therefore pin N of the pool's connections.

The e2e stack and prod both run the `config/runtime.exs` default
`POOL_SIZE=10` — nothing in the compose files overrides it. A runner with ≥10
schedulers could exhaust the pool from a single batch, before counting the other
channels, the checkpoint timers and the seq feed running on the same node.

Symptom in `docker-compose.log`:

```
Task #PID<...> started from #PID<...> terminating
** (DBConnection.ConnectionError) [Elixir.Engram.Repo] connection not available
   and request was dropped from queue after 183ms
    lib/engram/repo.ex:84:                       Engram.Repo.run_with_tenant/2
    lib/engram/notes.ex:690:                     Engram.Notes.genesis_crdt_note/4
    lib/engram_web/channels/crdt_channel.ex:455: EngramWeb.CrdtChannel.prepare_create/3
    lib/task/supervised.ex:101:                  Task.Supervised.invoke_mfa/2
```

**Rule:** derive concurrency from `pool_size`, not `System.schedulers_online()`.
`CrdtChannel.batch_concurrency/0` takes a quarter of the pool. The parallelism
win here is overlapping the SharedDoc round-trip with the DB write, which
saturates well below the pool size anyway — there is nothing to buy by going
higher, and a lot to lose.

### 2. `Task.async_stream` links its tasks to the caller

In a channel, the caller **is the channel process**. An unhandled raise or exit
in any task propagates through the link and kills the channel. After that the
socket holds no channel for the topic, so every subsequent client frame is
answered by Phoenix core (`deps/phoenix/lib/phoenix/socket.ex:871`) with:

```json
{"status": "error", "response": {"reason": "unmatched topic"}}
```

This is the part that makes the failure hard to read. The client-visible error
points at routing or auth and is emitted for messages that have nothing to do
with the batch — so one pool timeout during a bulk create failed three unrelated
e2e tests (test_77 bulk first sync, test_81 remote logging, test_85 missed
delivery), none of which touch the create-batch path.

`Enum.map(fn {:ok, res} -> res end)` over the stream is also a non-exhaustive
match: it has no clause for `{:exit, reason}`.

**Rule:** contain per-entry failures inside the task function
(`CrdtChannel.entry_guard/2`) and map them onto the per-entry error result the
handler's contract already defines. Log every occurrence — a swallowed pool
timeout is invisible until e2e goes red. If you need failures as stream values
instead, that requires `Task.Supervisor.async_stream_nolink/4` and a supervisor
in the tree; we did not add one for a single call site.

## Reading the symptom

| Client sees | Actual cause |
|---|---|
| `{"reason":"unmatched topic"}` on frames unrelated to the failure | the channel process died; socket no longer routes that topic |
| Bulk sync converges a fraction of notes then stalls | pool starved partway through the batch |
| Several unrelated e2e tests fail in one run, one of them under load | one crashed channel, not N independent flakes |

## Diagnosing

The pytest log alone is misleading — it shows the downstream timeouts, not the
cause. Go to the backend log in the CI debug artifact:

```bash
gh run download <run-id> -n ci-debug-<sha>
grep -oE "DBConnection[A-Za-z.]*|GenServer [^ ]+ terminating" docker-compose.log \
  | sort | uniq -c | sort -rn
```

`ci-*-stack.log` is only the image pull — the application logs are in
`docker-compose.log`. Grepping the wrong file returns zero hits and reads as
"no crashes", which is how this nearly got dismissed as a flake.

## Gotchas

- `Repo.with_tenant/2` keeps tenant context in the **process dictionary**
  (`:engram_tenant`), which a `Task` does NOT inherit. It happens to work here
  because `Notes.genesis_crdt_note/4` calls `with_tenant` itself, inside the
  task. Any parallelised code path that relies on an *outer* `with_tenant` will
  raise `Engram.TenantError` in the task instead.
- The test env pool (`config/test.exs`) is `schedulers_online() * 2 + 10`, much
  larger than prod's 10. A unit test will not reproduce pool starvation — only
  e2e under load will.
- Phase 2 of the batch (room enrollment) must stay serial in the channel
  process: `SharedDoc.observe`/`Process.monitor` have to register the channel
  pid, and socket assigns are mutated there. A task pid would swallow the
  room's `{:yjs, ...}` fan-out.

## Failed Approaches / Dead Ends

- **Blaming the tenant/RLS context.** Plausible (process dict is not inherited
  by tasks) but wrong — `genesis_crdt_note/4` establishes its own tenant scope.
  Checked before asserting; it cost one grep and would have cost hours as a
  theory.
- **Treating it as the known `e2e-clerk` flake** (#1136 / #355). Three failures
  in one run with a shared `unmatched topic` signature is a cascade, not three
  independent flakes. The tell is that the failures cluster in one run rather
  than moving between runs.

## References

- PR #1194, and its root-cause comment
- `lib/engram_web/channels/crdt_channel.ex` — `batch_concurrency/0`, `entry_guard/2`
- `lib/engram/repo.ex` — `with_tenant/2`, `prepare_query/3` tenant guard
- Prior instance of the same class:
  `engram-workspace/docs/context/crdt-sync-pool-exhaustion-loop-2026-07-09.md`

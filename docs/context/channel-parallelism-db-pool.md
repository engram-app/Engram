# Context Doc: Parallelising channel work against the DB pool

_Last verified: 2026-10-03_

## What This Is

Two traps hit when a Phoenix channel handler fans per-entry DB work out with
`Task.async_stream`, plus a unit-suite error that looks like pool starvation
and is not. First hit in `EngramWeb.CrdtChannel`'s `crdt_create_batch` (PR
#1194); that frame is gone, the traps are not. Read this BEFORE adding
parallelism to a channel.

## Trap 1: concurrency sized off the CPU, not the contended resource

`max_concurrency: System.schedulers_online()` is right for CPU-bound work and
wrong here. Each entry opening its own `Repo.with_tenant` **transaction** holds
a pooled connection for its whole duration, so N concurrent entries pin N
connections. Pool sizes are small: the `config/runtime.exs` default
`POOL_SIZE=10` (what e2e runs), and prod sets 15-25 per role (engram-infra
`main/envs/prod/ecs.tf`). One batch on a many-core runner can exhaust it before
counting other channels, checkpoint timers and the seq feed. Symptom:
`DBConnection.ConnectionError ... connection not available and request was
dropped from queue`.

**Rule:** derive concurrency from `pool_size` (a fraction of it), not from
schedulers. Overlapping one external round trip with the DB write saturates
well below the pool size anyway.

## Trap 2: `Task.async_stream` links its tasks to the caller

In a channel the caller **is the channel process**. A raise or exit in any
task kills the channel, and every later client frame on that topic is answered
by Phoenix core with:

```json
{"status": "error", "response": {"reason": "unmatched topic"}}
```

That error points at routing or auth and hits frames unrelated to the batch, so
one pool timeout fails several unrelated e2e tests in the same run.
`Enum.map(fn {:ok, res} -> res end)` over the stream also has no clause for
`{:exit, reason}`.

**Rule:** contain per-entry failures inside the task function, map them onto
the handler's per-entry error result, and log every occurrence. If you need
failures as stream values instead, use `Task.Supervisor.async_stream_nolink/4`
with a supervisor in the tree.

## Reading the symptom

| Client sees | Actual cause |
|---|---|
| `{"reason":"unmatched topic"}` on unrelated frames | the channel process died |
| Bulk sync converges a fraction of notes then stalls | pool starved mid-batch |
| Several unrelated e2e tests fail in one run | one crashed channel, not N flakes |

In CI artifacts the application log is `docker-compose.log`; `ci-*-stack.log`
is only the image pull. Grepping the wrong file returns zero hits and reads as
"no crashes".

## Gotchas

- `Repo.with_tenant/2` keeps the tenant in the **process dictionary**, which a
  `Task` does not inherit. Code relying on an *outer* `with_tenant` raises
  `Engram.TenantError` in the task; call `with_tenant` inside the task.
- The test pool (`config/test.exs`) is `schedulers_online() * 2 + 10`, far
  larger than prod's. A unit test will not reproduce real pool starvation.

## The test-sandbox variant (different mechanism, near-identical error)

Under `Ecto.Adapters.SQL.Sandbox`, a process a test spawns does **not** check
out its own connection; it shares the **owner's** one. Fanning out serialises
every transaction through that connection. Queueing is the designed behaviour,
and `pool_size` is not in the picture.

What fails is `DBConnection`'s overload shedding. Its defaults
(`queue_target: 50ms`, `queue_interval: 1000ms`) suit a production pool; under
full-suite load the honest serialisation wait crosses 50ms and entries die
with:

```
** (DBConnection.ConnectionError) could not checkout the connection owned by
   #PID<...> (:proc_lib). When using the sandbox, connections are shared, so
   this may imply another process is using a connection. Reason: connection not
   available and request was dropped from queue after 101ms
```

**The tell is `could not checkout the connection owned by #PID`.** Pool
starvation says the pool is empty; this says one owner's connection was
contended. Raising `pool_size` cannot fix it.

Fixed in PR #1218: `queue_target`/`queue_interval` raised to 5s/30s in
`config/test.exs`, sandbox only. The 15s checkout timeout is left alone so a
real deadlock or leaked connection still fails the run. Re-verify cheaply by
forcing `queue_target: 8`, which reproduces the error with no load.

## References

- PR #1194 (channel traps), PR #1218 (sandbox queue settings)
- `lib/engram/repo.ex`: `with_tenant/2`, `prepare_query/3`
- Prod pool-starvation signature and budget:
  `../engram-workspace/docs/context/prod-db-connection-budget.md`

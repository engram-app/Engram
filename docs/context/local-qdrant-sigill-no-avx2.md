# Local Qdrant dies mid-upsert: `socket closed` against a "healthy" container

_Last verified: 2026-09-11_

**Trigger:** a bulk upsert into a local Qdrant collection fails on the first
batch, from Elixir:

```
** (Req.TransportError) socket closed
```

...and every obvious check says the container is fine. It is not fine: the
Qdrant process was killed with **SIGILL (illegal opcode)** because this dev
host's CPU has no AVX2, and Qdrant's binary-quantization encoder takes an
AVX2/FMA SIMD path.

**Scope: this dev host only.** Prod runs Qdrant Cloud on modern CPUs and is
unaffected. Nothing here is a product bug.

## The misleading evidence (this is the time sink)

Batch size is not the variable. It reproduced identically at 500 points/batch
and at 100 points/batch, always on the very first batch, upserting 25,000
points total.

`docker inspect` looks clean:

```bash
docker inspect engram-dev-qdrant \
  --format 'status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} mem={{.HostConfig.Memory}}'
# status=running exit=0 oom=false mem=0
```

`oom=false`, no memory limit, and `free -m` showed ~20 GB available — so it
reads as "not OOM, not crashed, still running." All of that is true *after the
restart*. The restart policy is `unless-stopped`, so Docker already brought it
back before you looked.

**The one field that tells the truth:**

```bash
docker inspect --format '{{.RestartCount}}' engram-dev-qdrant
```

It increments once per attempt (1, then 2, ...). A rising `RestartCount` with
`status=running` means it died and came back, not that it never died.

> Contrast with `docs/context/ci-registry-down-during-appdata-backup.md`, where
> `restarts=0` under `unless-stopped` was the tell for the *opposite* diagnosis
> (deliberately stopped, not crashing). Same field, both directions.

`docker logs` is useless here — it shows nothing at the moment of death, only a
normal boot/recovery sequence afterwards. The process is killed hard by the
kernel, so there is no application-level error to find. Absence of a Qdrant
error in the logs is evidence *for* this diagnosis, not against it.

## The actual evidence: the kernel log

```bash
journalctl -k --since "<time of the failed run>" | grep -i oom
```

```
kernel: traps: update-15[1837438] trap invalid opcode ip:... in qdrant[...]
```

Two things to read off that line:

- **`trap invalid opcode` is SIGILL, not OOM.** Grepping `oom` finds it anyway
  (the word appears in the trap line's surroundings), which is convenient, but
  do not let the grep term talk you into an OOM story — `oom=false` above was
  correct.
- **`update-15` is a Qdrant update worker thread.** The crash is on the
  update/optimizer path, which is where quantization work happens.

## Root cause

```bash
grep -o -E '\b(avx|avx2|fma|sse4_1|sse4_2|f16c)\b' /proc/cpuinfo | sort -u
grep -m1 'model name' /proc/cpuinfo
```

- CPU: `Intel(R) Xeon(R) CPU E5-2650 v2 @ 2.60GHz` (Ivy Bridge)
- Flags present: `sse4_1 sse4_2 avx f16c`
- Flags **absent**: `avx2`, `fma`
- Image: `qdrant/qdrant:v1.17.1`

Qdrant's binary-quantization encoder dispatches to an AVX2/FMA SIMD path and
executes an instruction this CPU does not implement. The kernel kills the
process.

## Why it hides until you do bulk work

A single-point upsert into a binary-quantized collection does not trip it. The
existing `:qdrant_integration` tests upsert one point, so **they pass on this
host.** The crash only fires once the update/optimizer path does real
quantization work at volume. A green integration suite says nothing about
whether bulk indexing will survive here.

## Workaround: create the collection without quantization

Binary quantization is already switchable — it is not a code change.

| Where | How |
|---|---|
| Env var (read in dev too — `config/runtime.exs:202`, guarded only by `config_env() != :test` at `:37`) | `QDRANT_BINARY_QUANTIZATION=false` |
| Inside a one-off script / IEx | `Application.put_env(:engram, :qdrant_binary_quantization, false)` |

Both land on `ServiceConfig.get(:qdrant_binary_quantization, true)` in
`lib/engram/vector/qdrant.ex:37`, which gates two sites:

- collection creation (`:193`) — omits `quantization_config` entirely
- per-query params (`:631`) — skips the binary funnel + rescore

The switch must be set **before the collection is created**; it changes the
create body, so an already-quantized collection stays quantized.

**Payload-index measurements are unaffected.** Payload indexes are built from
payload, not vectors, so turning quantization off does not distort
payload-index timing work.

## Gotchas

- Do not raise the batch size looking for a threshold — there isn't one. First
  batch, every time.
- Do not chase memory. `oom=false` and 20 GB free are both accurate and both
  irrelevant.
- This host has bitten us the same way before, with a different binary: the
  prebuilt Supabase CLI SIGILLs here because it is compiled `GOAMD64=v3`. See
  `docs/context/local-supabase-audit.md` (Gotcha 1). **Any prebuilt binary that
  assumes AVX2 is suspect on this machine.**

## References

- `lib/engram/vector/qdrant.ex` — `binary_quantization_enabled?/0` (:37), create body (:193), query params (:631)
- `config/runtime.exs:202` — `QDRANT_BINARY_QUANTIZATION` wiring
- `docs/context/environment-variables.md` — the env-var row
- `docs/context/local-supabase-audit.md` — same CPU, same missing-AVX2 class
- `docs/context/ci-registry-down-during-appdata-backup.md` — the `RestartCount` diagnostic, read the other way

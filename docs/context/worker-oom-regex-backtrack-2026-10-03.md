# Worker OOM crash-loop from a regex backtrack (2026-10-03)

**Rule.** Any regex run over note content with a repeated alternation group
must be possessive (`*+`, `++`) or atomic. PCRE keeps a backtrack frame per
iteration of such a group, and on the BEAM that costs about 0.8 KB per
character matched. A plain char-class repeat like `[^x]*` is optimized by PCRE
and is safe (fuzz confirmed).

## Incident

- 2026-10-03 10:02 MT a new user imported 342 notes.
- `engram-worker-prod` (0.5 vCPU / 1 GiB, 820 MB container cap) was OOM-killed
  (exit 137, `OutOfMemoryError: container killed due to memory usage`) every
  1-14 min for about 6h.
- Mitigated 16:38 MT: parked 4 notes (`embed_retry_after` +30d) and cancelled
  36 `EmbedNote` jobs via ECS exec rpc on a web task.

Trigger note shape (aggregate counts only, no content read): 2.6 MB, 81%
base64 (3 inline `![](data:image/png;base64,...)` images, 2.12 MB), one 1.87 MB
line, 1,339 chunks.

## Root cause

`Engram.Links.Parser` `@md_link_re` destination group
`(?:[^()]|\([^()]*\))*` matched one character per iteration, so a base64 data
URI inside `![](...)` became millions of backtrack frames.

| Destination length | Original | Possessive `(?:[^()]++\|\([^()]*+\))*+` |
|---|---|---|
| 100 KB | 237 ms, +77 MB | |
| 500 KB | 2.3 s, +393 MB | |
| 1 MB | 5.6 s, +787 MB | 14 ms, 0 MB, same matches |

## Secondary fixes (branch `fix/embed-worker-oom`)

- **Packed vectors.** Indexing held every chunk's 1024-d vector as an Elixir
  float list (~32 B/float on heap) until commit. Now packed float32 binaries,
  unpacked per Qdrant batch. Upsert batch 256 -> 64 (JSON encoding a 256 batch
  peaked ~54 MB heap). `max_heap_size` test: old code killed at 200 MB, new
  passes at 80 MB for a 2,000-chunk note. Heap now scales ~3.7 KB/chunk
  (19 MB @ 2k chunks, 30 MB @ 5k sampled).
- **Vectors as JSON fragments.** Unpacking each batch back to float lists for
  Jason was then the heap peak (~26 MB per 64-point batch). The array text is
  now encoded straight from the float32 binary and passed as a
  `Jason.Fragment`. Heap-cap test at 35 MB: old killed 3/3, new passes 3/3.
- **Base64 blob filter.** Runs of 100+ base64-alphabet chars mixing
  upper/lower/digits (plus optional `data:` prefix) are stripped from chunk
  text. `chunker_version` bumped to 2.
- **Crash-loop guard in `EmbedNote`.** An OOM kill never returns, so
  `maybe_mark_poison` never fires. Oban Lifeline (Oban 2.24 Basic engine
  `rescue_jobs`) re-queues orphans WITHOUT recording an error, and
  `ReconcileEmbeddings` (#897 fixed short backoff) keeps enqueuing. The guard
  counts hard deaths = attempts started minus errors recorded across the
  note's `EmbedNote` rows in 24h (excluding fresh executing and completed).
  At >= 2 it stamps a 6h poison cooldown, logs `embed_crash_quarantined`, and
  returns `{:cancel, :repeated_node_death}`.

End-to-end local repro (real `EmbedNote.perform`, real Qdrant, out-of-BEAM
Voyage stub), note A peak RSS delta:

| Change | Peak RSS delta |
|---|---|
| Original | +671 MB |
| + regex fix | +485 MB |
| + packed vectors | +162 MB |
| + blob filter | +125 MB (59 s -> 14.6 s) |
| + JSON fragments, language models warm (as prod) | +28 MB |

The +125 MB row includes ~55 MB of one-time Lingua model load (off-heap, NIF)
that prod pays at boot via `LangDetect.warmup/0`; measure with it warm or the
number misleads. What remains is mostly the per-chunk live set (sparse
vectors, encrypted payloads, chunk rows, ~8 KB/chunk) plus allocator
retention, which RSS shows and `:erlang.memory/0` does not.

## Why nothing alerted

Worker CloudWatch alarms exist (`engram-prod-worker-memory-high` at 75%,
`worker-not-running`), but the balloon lived ~10 s between 1-minute samples
(sampled max 41%) and ECS replaced tasks in seconds. Loki never saw crash
output, since only structured `loki_ship` lines ship.

Fix in engram-infra branch `feat/worker-crash-alerts`: EventBridge
`ECS Task State Change` STOPPED + `stopCode EssentialContainerExited` ->
prod-alerts SNS -> Discord relay formatter `[ECS-TASK-CRASH]`, plus a notify
Loki rule on `embed_crash_quarantined`.

## Remaining hotspots (not fixed, follow-ups)

Fuzz of 25 adversarial 1 MB shapes over title/tags/frontmatter/links/chunker/sparse:

- Many tiny headings (200K): `md.parse` +329 MB / 7.9 s, and every tiny
  section becomes its own chunk.
- Huge YAML frontmatter: `Frontmatter.parse` 39 s CPU.
- Tokenize + sparse: 10-25 s CPU per MB.
- Invalid UTF-8 crashes `extract_tags`/tokenizer with `:re` badarg. Unreachable
  today because write and read paths scrub UTF-8 first.

## Ops gotchas

- ECS exec output is cut when the session closes. Have the rpc write to a file
  and `cat` it in a second exec.
- `pkill -f` / `pgrep -f` with a pattern that appears in your own bash command
  kills that shell (exit 144).
- `mix run -e CODE file.exs` silently skips the file.
- The shared local `engram_test` DB can carry tables from other worktrees'
  migrations. Use `MIX_TEST_PARTITION=N` for a fresh DB.

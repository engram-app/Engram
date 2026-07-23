# Context Doc: Lingua language-detection memory (the `low_accuracy_mode` dial)

_Last verified: 2026-07-03_

## Status
Working — `low_accuracy_mode: true` set in `lib/engram/keyword_index/lang_detect.ex` (PR fixing #891/#892).

## What This Is
`Engram.KeywordIndex.LangDetect` does per-chunk Latin-script language detection (to route the keyword-index stemmer) via the **`Lingua` NIF** (precompiled Rust wrapper around lingua-rs). Its language models are large and live off-heap in the Rust NIF — this doc records how big, how they load, and the dial that controls it.

## The key facts (measured on prod, 2026-07-03)
- lingua-rs caches n-gram models in a **process-global static** inside the NIF. Models load **lazily on first use** and stay resident for the node's lifetime.
- It is a **single shared load per BEAM node** — NOT per detection call, per Elixir process, or per note. (Proof: under 8-concurrent load the footprint grew to a ceiling and then stayed flat across further rounds; per-instance would have multiplied it.) Each node in a cluster loads its own copy.
- Footprint by mode, for `builder_option: :all_languages_with_latin_script`:
  - **full accuracy (default):** uni/bi/tri/quad/five-gram models → **~945 MB** resident.
  - **`low_accuracy_mode: true`:** **trigram-only** → **~135 MB** resident (~7× smaller). Plateaus; does not grow with more text.
- The memory is **off-heap** — invisible to `:erlang.memory` / PromEx BEAM metrics. Only container RSS / `smaps` `Anonymous` / ECS `MemoryUtilized` see it.

## Why it mattered (incident #891/#892)
On the 1024 MB Fargate task (512 CPU / 1024 MB, 3 containers, no per-container limits), full-accuracy model loading during an indexing burst pushed the engram container to the task ceiling → `OutOfMemoryError` → OOM crash-loop, connection-independent. Because the load is one-time-global and reaches ~945 MB **regardless of embed concurrency**, lowering `embed` concurrency alone does NOT bound it — `low_accuracy_mode` is the actual fix.

## The dial
`lib/engram/keyword_index/lang_detect.ex`, in the `Lingua.detect/2` call:
```elixir
low_accuracy_mode: true,   # trigram-only ~135 MB; false = full ~945 MB/node
```
Trade memory back for accuracy by flipping to `false` — but budget ~945 MB resident NIF memory **per node** and raise the ECS task memory accordingly. For our use (coarse language ID to pick a stemmer, gated at `@floor 0.40` confidence with a raw-index fallback), low accuracy is sufficient.

## How to measure it
The FireLens `null` output blacks out app logs (see #894), so measure via a one-off ECS task that `eval`s a script writing to S3:
- Start the app (Oban neutralized), warm `Lingua.detect(..., low_accuracy_mode: <mode>)` over real note chunks, 8-concurrent, 2+ rounds.
- Sample `/proc/self/smaps_rollup` `Anonymous:` (the off-heap number) — `:erlang.memory` will NOT show it.
- Run each mode in a **separate task** — the global model cache persists for the process life, so you can't compare modes in one process.

## Gotchas
- `:erlang.memory` and PromEx BEAM memory panels will look fine (~150 MB) while RSS is ~1 GB — always cross-check container `MemoryUtilized` / `smaps` for NIF-heavy paths.
- `Lingua.detect/2` rebuilds a `LanguageDetector` object per call (`native/.../lib.rs:83 builder.build()`), but that's cheap — the models are the global cache, not the detector object. Caching the detector object would NOT save memory; changing which models load (this dial / language restriction) is what matters.
- `compute_language_confidence_values: true` scores against all candidate languages.

## References
- `lib/engram/keyword_index/lang_detect.ex` (the dial + moduledoc table)
- Issues: #891 (p0 incident), #892 (this root cause)

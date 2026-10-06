# Context Doc: Lingua language-detection memory (the `low_accuracy_mode` dial)

_Last verified: 2026-10-06_

## Status
Working — low accuracy mode set in `native/engram_native/src/lang_detect.rs` (since 2026-10-06; before that `low_accuracy_mode: true` on the `lingua` hex package's `Lingua.detect/2`, PR fixing #891/#892).

## What This Is
`Engram.KeywordIndex.LangDetect` does per-chunk Latin-script language detection (to route the keyword-index stemmer) via lingua-rs inside our own `engram_native` NIF (`Engram.Native.lang_detect/1`; it was the `lingua` hex package until 2026-10-06). Its language models are large and live in the Rust NIF — this doc records how big, how they load, and the dial that controls it.

## The key facts (measured on prod, 2026-07-03)
- lingua-rs caches n-gram models in a **process-global static** inside the NIF. Models load **lazily on first use** and stay resident for the node's lifetime.
- It is a **single shared load per BEAM node** — NOT per detection call, per Elixir process, or per note. (Proof: under 8-concurrent load the footprint grew to a ceiling and then stayed flat across further rounds; per-instance would have multiplied it.) Each node in a cluster loads its own copy.
- Footprint by mode, for `builder_option: :all_languages_with_latin_script`:
  - **full accuracy (default):** uni/bi/tri/quad/five-gram models → **~945 MB** resident.
  - **`low_accuracy_mode: true`:** **trigram-only** → **~55 MB** resident. Plateaus; does not grow with more text. (Re-measured 2026-08-18 by sampling RSS around the first `Lingua.detect/2`: +55 MB on call 1, flat across 400 more. The earlier ~135 MB figure was not reproducible.)
- Since 2026-10-06 the models are allocated through `enif_alloc` (our global allocator), so `:erlang.memory(:system)` and `Engram.Native.live_bytes/0` count them (~46 MB). Under the hex package they were off-heap and invisible to `:erlang.memory`; only RSS / `smaps` `Anonymous` saw them.

## Why it mattered (incident #891/#892)
On the then 1024 MB Fargate task (shared by 3 containers, no per-container limits), full-accuracy model loading during an indexing burst pushed the engram container to the task ceiling → `OutOfMemoryError` → OOM crash-loop, connection-independent. Because the load is one-time-global and reaches ~945 MB **regardless of embed concurrency**, lowering `embed` concurrency alone does NOT bound it, `low_accuracy_mode` is the actual fix.

## The dial
`native/engram_native/src/lang_detect.rs`, where the one detector is built:
```rust
.with_low_accuracy_mode()   // trigram-only ~55 MB; without it full ~945 MB/node
```
Trade memory back for accuracy by removing it — but budget ~945 MB resident NIF memory **per node** and raise the ECS task memory accordingly. For our use (coarse language ID to pick a stemmer, gated at `@floor 0.40` confidence with a raw-index fallback), low accuracy is sufficient.

## How to measure it
Measure from a one-off ECS task (or locally) rather than inferring from BEAM metrics:
- Start the app (Oban neutralized), warm `Engram.Native.lang_detect/1` over real note chunks, 8-concurrent, 2+ rounds.
- Sample `/proc/self/smaps_rollup` `Anonymous:` (the off-heap number) — `:erlang.memory` will NOT show it.
- Run each mode in a **separate task** — the global model cache persists for the process life, so you can't compare modes in one process.

## Gotchas
- `:erlang.memory` and PromEx BEAM memory panels will look fine (~150 MB) while RSS is ~1 GB — always cross-check container `MemoryUtilized` / `smaps` for NIF-heavy paths.
- The hex package rebuilt a `LanguageDetector` per call. Measured 2026-10-06: ~0.1 ms, and caching it (the port) saved no memory and no meaningful time (2K chars ~5 ms either way, all trigram scoring). Changing which models load (this dial / language restriction) is what matters.
- `compute_language_confidence_values: true` scores against all candidate languages.

## References
- `lib/engram/keyword_index/lang_detect.ex` (the dial + moduledoc table)
- Issues: #891 (p0 incident), #892 (this root cause)

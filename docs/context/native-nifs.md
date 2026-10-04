# In-house Rust NIFs (`native/`)

The keyword encoder (tokenize + Snowball stem + HMAC + BM25) was the first
port, on 2026-10-04. This doc is the standard every later NIF follows.

## Default to Rust for CPU-bound pure work

**Policy: when code is CPU-bound and pure, write it (or port it) as a function
in `native/engram_native`. Do not reach for it as a last resort.** Elixir does
the orchestration: jobs, I/O, processes, retries, tenancy. Rust does the
loops over bytes. The first port ran 15-43x faster with a native peak in
single-digit MB, where the Elixir version needed tens to hundreds of MB of
heap. That gap is typical for text processing, not a fluke.

Port it when ALL of these hold:

1. **Pure:** binaries/numbers in, binaries/numbers out. No DB, no network,
   no process state, no callbacks into Elixir.
2. **CPU-bound:** it scans or transforms bytes (parse, tokenize, hash, regex,
   normalize, encode, diff). A profile or a timing shows it in milliseconds
   or more per call, or it builds large term structures on the heap.
3. **Testable against the old code:** there is an Elixir version (or a spec)
   to diff against before it is deleted.

Do NOT port: anything that waits on I/O (Voyage, Qdrant, Postgres, S3: Rust
buys nothing there), code under a few microseconds per call (the NIF call
costs about that), or code that needs to call back into the BEAM.

### Next candidates (measured or observed, highest value first)

| Code | Why | Evidence |
|---|---|---|
| `Engram.Parsers.Markdown.parse/2` (chunker, blob strip, frontmatter) | regex-heavy, runs on every embed | fuzz 2026-10-03: huge frontmatter ~39 s CPU/MB; many tiny headings ~8 s and +329 MB per MB |
| `Engram.Links.Parser.extract/1` | regex scan of the whole note on every edit | caused the 2026-10-03 OOM (PCRE backtrack frames) before the possessive fix |
| `Indexing` packing/JSON of vectors (`dense_json`, `vector_json`) | per-float formatting over 1024-dim vectors | hot during upsert of large notes |
| Content fingerprints (`Crypto.hmac_content_hash` over `context_text`) | one HMAC per chunk, plus string building | cheap per call; port together with the chunker, not alone |

Port the chunker and link parser as ONE pass over the note (both read the
same bytes), behind their existing module APIs, the way the keyword encoder
kept `Tokenizer`/`QdrantSparse`.

Measured on the keyword encoder (dev box, minimum of 5 interleaved runs):

| Input | Elixir | Rust | Native peak |
|---|---|---|---|
| 1.1 MB prose, 1,693 chunks | 3,994 ms | 263 ms | 1.4 MB |
| 4.8 MB unique words, 4,000 chunks | 98,575 ms | 2,292 ms | 2.1 MB |

The Elixir encoder needed a 20-160 MB heap for the second input.

## The memory standard

BEAM tooling (`:erlang.memory/0`, `max_heap_size`, recon_alloc) cannot see a
NIF's own `malloc`; it is how y_ex's memory went unseen. Each of the
following closes part of it:

1. **Allocate through the BEAM.** `native/engram_native/src/memory.rs` is the
   `#[global_allocator]`: rustler's `EnifAllocator` (so the bytes land in
   `:erlang.memory(:system)`) wrapped in a counter. Not active under
   `cargo test`, where no BEAM exists.
2. **Report every call's peak.** A dirty-scheduler NIF runs start to finish
   on one OS thread, so a thread-local live/peak pair, reset on entry, is
   that call's native high-water mark. Exact only if the NIF spawns no
   threads: **ours must not** (no rayon).
3. **One telemetry shape for every NIF.** `Engram.Native.call/3` emits
   `[:engram, :nif, :call, :stop]` with `duration`, `native_peak_bytes`,
   `input_bytes`, metadata `%{nif: atom}`. `Engram.PromEx.Native` exports it.
4. **Watch what nobody attributes.** `[:engram, :vm, :native_memory]` (polled
   every 15 s) reports `rss - :erlang.memory(:total)` as `unaccounted`. A
   third-party NIF on its own allocator only shows up there. It is tens of
   MB at boot (code, shared libraries) and can go negative (the BEAM counts
   allocated memory the OS has not made resident), so alert on growth, not
   level.
5. **Never a hard allocation limit.** A null from the allocator aborts the
   whole node and `catch_unwind` cannot stop it. Bound memory by design and
   prove it with the peak instead (below).

## Tests every NIF ships with

- **Peak bound** (the `max_heap_size` analogue): pathological inputs (one
  huge token, many chunks) and `assert peak <= k * input_bytes + slack`.
  Peak per input byte depends on the input's shape (one huge CJK word
  measured ~30x), so the real bound is on the INPUT: bound what each call
  receives (below).
- **Bound every input at the Elixir wrapper.** The keyword encoder takes at
  most 256 chunks (each at most 2 KB) per call and reads at most 4,096
  characters of a query, and does not stem tokens over 64 bytes (some
  generated Snowball stemmers are quadratic in word length: a 200 KB "word"
  took 4 s). Guards that the Elixir code had (key length, `avgdl > 0`) stay
  in the wrapper: a NIF returns garbage where Elixir raised.
- **Leak:** warm up once (lazy statics are permanent), then 300 calls and
  `assert live_bytes() - before == 0`.
- **Behaviour parity:** when porting, capture golden output from the Elixir
  code BEFORE deleting it, and keep its behaviour tests running against the
  NIF. The keyword port kept `tokenizer_test.exs` and `qdrant_sparse_test.exs`
  unchanged and added a 490-case golden set
  (`test/support/fixtures/keyword_tokens_golden.json`).

## Scheduling

`schedule = "DirtyCpu"` on everything whose input size the caller controls.
Dirty CPU schedulers cannot be preempted and default to one per normal
scheduler. **Prod tasks run ONE** (`task_cpu_units = 512` → `BEAM_SCHEDULERS=1`,
`+SDcpu 1:1`, engram-infra `main/envs/prod/ecs.tf`, `rel/env.sh.eex`), shared
with lingua and mdex_native. Calls queue behind each other there, which is
fine while each is short (the keyword encode is ~0.25 s per MB). If a NIF ever
runs for seconds per call in prod, chunk the input or raise `+SDcpu` before
adding callers.

## Build

- Toolchain pinned in `native/engram_native/rust-toolchain.toml` and installed
  by rustup in the Dockerfile builder stage and CI's mix-builder image (keep
  the three versions in sync). Runner-host jobs install rustup into the
  runner user's home once per VM. The runtime image has no Rust.
- Compiled from source by `mix compile` (rustler), not rustler_precompiled:
  that pipeline is for Hex packages.
- Build for baseline x86-64. Never `-C target-cpu=native`: CI runners and
  Fargate are different CPUs.
- CI change detection (`ci/fingerprint/groups.sh`) hashes `native/` with the
  Elixir source, and the `_build` caches carry `priv/native` (the built
  `.so`). Without the latter a host job restores a manifest that says the
  crate is compiled and loads a missing or stale library.
- Adding a NIF function: add it to the Rust `#[rustler::nif]` list AND the
  stub in `Engram.Native`, route it through `call/3` so it emits telemetry,
  and give it a peak-bound and a leak test.

## Gotchas found on the way

- **OTP's regex Unicode is from 2021.** OTP 27 bundles PCRE 8.45, whose
  Unicode tables disagree with current Unicode on ~39k codepoints. The Elixir
  tokenizer classified characters with them, and OTP 28 (PCRE2) would have
  changed tokens silently on upgrade. The Rust tokenizer uses current Unicode,
  pinned by `Cargo.lock`. A tokenizer change needs
  `ReindexKeyword.enqueue(user_id, vault_id, :sparse)`: a keyword-only
  re-index with no Voyage spend. Run it only once the WORKER tier is on the
  new release (`count by (role) (up{job="prometheus.scrape.engram_app"})`):
  an old worker reads a `:sparse` job as a full, Voyage-billed re-embed, and
  has no `ResparseNote` module at all.
- **`str::to_lowercase` applies Greek final sigma; `String.downcase` does
  not.** Lowercase per char (`flat_map(char::to_lowercase)`).
- **Stemmers:** generated with the Snowball compiler (`regen.sh`) from the
  same `.sbl` files the Elixir stemmer shipped, NOT the `rust-stemmers` crate
  (nine of our `.sbl` files differ from Snowball upstream).
- **Index order is not part of the sparse contract.** Qdrant sorts indices on
  upsert and rejects duplicates, so the NIF emits sorted, merged indices.
- **This dev box cannot run Qdrant.** Its Xeon E5-2650 v2 lacks AVX2, and
  Qdrant 1.17 dies with SIGILL (exit 132) on collection create. Qdrant
  integration tests run in CI only.

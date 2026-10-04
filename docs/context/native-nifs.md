# In-house Rust NIFs (`native/`)

The keyword encoder (tokenize + Snowball stem + HMAC + BM25) was the first
port, on 2026-10-04. This doc is the standard every later NIF follows.

## When a NIF is worth it

Only for pure CPU work over binaries, after a profile shows it hot. The Oban
flow is mostly I/O (Voyage, Qdrant, Postgres), where Rust buys nothing.

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
   MB at boot (code, shared libraries), so alert on growth, not level.
5. **Never a hard allocation limit.** A null from the allocator aborts the
   whole node and `catch_unwind` cannot stop it. Bound memory by design and
   prove it with the peak instead (below).

## Tests every NIF ships with

- **Peak bound** (the `max_heap_size` analogue): pathological inputs (one
  huge token, many chunks) and `assert peak <= k * input_bytes + slack`.
- **Leak:** warm up once (lazy statics are permanent), then 300 calls and
  `assert live_bytes() - before == 0`.
- **Behaviour parity:** when porting, capture golden output from the Elixir
  code BEFORE deleting it, and keep its behaviour tests running against the
  NIF. The keyword port kept `tokenizer_test.exs` and `qdrant_sparse_test.exs`
  unchanged and added a 490-case golden set
  (`test/support/fixtures/keyword_tokens_golden.json`).

## Scheduling

`schedule = "DirtyCpu"` on everything whose input size the caller controls.
Dirty schedulers equal normal ones in number by default and cannot be
preempted, so keep concurrent callers (the Oban queue limit) below
`:erlang.system_info(:dirty_cpu_schedulers)`.

## Build

- Toolchain pinned in `native/engram_native/rust-toolchain.toml` and installed
  by rustup in the Dockerfile builder stage and CI's mix-builder image (keep
  the three versions in sync). Runner-host jobs install rustup into the
  runner user's home once per VM. The runtime image has no Rust.
- Compiled from source by `mix compile` (rustler), not rustler_precompiled:
  that pipeline is for Hex packages.
- Build for baseline x86-64. Never `-C target-cpu=native`: CI runners and
  Fargate are different CPUs.

## Gotchas found on the way

- **OTP's regex Unicode is from 2021.** OTP 27 bundles PCRE 8.45, whose
  Unicode tables disagree with current Unicode on ~39k codepoints. The Elixir
  tokenizer classified characters with them, and OTP 28 (PCRE2) would have
  changed tokens silently on upgrade. The Rust tokenizer uses current Unicode,
  pinned by `Cargo.lock`. A tokenizer change needs
  `ReindexKeyword.enqueue(user_id, vault_id, :sparse)`: a keyword-only
  re-index with no Voyage spend.
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

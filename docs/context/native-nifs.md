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
| `Engram.Notes.Frontmatter.emit/3` (Ymlr) | Ported and NOT shipped (2026-10-06, #1877): byte-identical on 200k pairs but only 2-3x (10 keys 32 -> 14 us), and any drift shifts `content_hash` and re-embeds notes. Code on branch `perf/sync-audit-yaml` (`6959fd4b`) | revisit only if emit shows up in a profile |

Measured on the chunker (`chunk`, `frontmatter_split`, 2026-10-04,
`Markdown.parse/2` end to end, best of 3; "Elixir" is chunker v2 on `main`,
"Rust" is chunker v3):

| Input | Elixir | Rust | Native peak |
|---|---|---|---|
| 243 docs, 3.1 MB | 743 ms | 365 ms | 0.4 MB max |
| 1 MB prose | 273 ms | 63 ms | 1.1 MB |
| 680 KB code-heavy | 3,009 ms, 40,001 chunks | 231 ms, 333 chunks | 1.2 MB |
| 2 MB data-URI image | 66 ms | 127 ms | 2.0 MB |

The v2 port first matched the Elixir chunker byte for byte (2,008-note golden
set), then v3 changed boundaries under one `@chunker_version` bump. v3 cuts an
oversized section after a unit whose hash is the maximum within 1 KB either
side, so a cut depends only on nearby text. On 400-paragraph notes, an edit
re-embeds 1.25-1.8 chunks and a deleted paragraph 1.4-1.9, against 15-40 and
25-86 under greedy packing (whose every later boundary shifts). A first try
with hash anchors plus a minimum chunk size kept edits local but not
deletions: the minimum made each cut depend on where the chunk began.
`chunker_golden.json.gz` pins v3 output; regenerate it only with a version
bump.

Measured on the search and upsert NIFs (2026-10-04, dev box, min of 5-7,
identical output to the Elixir they replaced):

| NIF | Input | Elixir | Rust |
|---|---|---|---|
| `json_decode` (Qdrant query body) | 200 x 1024 vectors, 2.3 MB | 270-290 ms | 59-65 ms |
| `mmr_select` | 200 x 1024 pool, limit 50 | 654 ms | 28.5 ms |
| `dense_json` | 2,000 x 1024-d | 542 ms | 106 ms (text 43% smaller) |
| `sparse_json` | 2,000 x 200 dims | 205 ms | 38 ms |
| `pack_f32` | 2,000 x 1024 floats | 175 ms | 44 ms |
| `hmac_hex_many` | 2,000 x 2 KB / 5 x 1.5 KB | 53.7 ms / 56 us | 28.6 ms / 39 us |

`hmac_hex_many` beats OpenSSL-backed `:crypto.mac` only because it BATCHES:
one call per note, no prefixed copy per chunk, hex in Rust. A per-chunk NIF
would have lost to the NIF call overhead. Batch small pure calls; do not
port them one-for-one.

Measured on the CRDT text diff (`text_diff`, 2026-10-06,
`CrdtBridge.diff_into_text/2` end to end including the Yex edit, min of 5;
#1873). The Elixir version walked codepoint lists; the NIF compares bytes,
backs off to a codepoint boundary, and allocates nothing (peak 0). The
insert comes back as a byte range so Elixir slices it with `binary_part`:

| Input | Elixir | Rust |
|---|---|---|
| 5 KB prose, mid edit | 3.9 ms | 0.05 ms |
| 100 KB prose, mid edit | 60 ms | 0.8 ms |
| 1 MB prose, mid edit | 1,256 ms | 8 ms |
| 1 MB prose, append | 980 ms | 9 ms |
| 1 MB emoji, mid edit | 672 ms | 12 ms |
| 1 MB full replace | 2,044 ms | 13 ms |

Measured on the keyword encoder (dev box, minimum of 5 interleaved runs):

| Input | Elixir | Rust | Native peak |
|---|---|---|---|
| 1.1 MB prose, 1,693 chunks | 3,994 ms | 263 ms | 1.4 MB |
| 4.8 MB unique words, 4,000 chunks | 98,575 ms | 2,292 ms | 2.1 MB |

The Elixir encoder needed a 20-160 MB heap for the second input.

Measured on the link parser (`link_extract`, 2026-10-04, `Links.Parser.extract/1`
end to end, minimum of 5, loaded dev box):

| Input | Elixir regex parser | Rust | Peak: Elixir heap / native |
|---|---|---|---|
| 1 MB code-heavy | 14,293 ms | 75 ms | 93 MB / 7 MB |
| 1 MB tight list | 20,107 ms | 115 ms | 12 MB / 3 MB |
| 1 MB prose, 50k links | 1,064 ms | 121 ms | 26 MB / 18 MB |
| 2.7 MB data-URI image | 387 ms | 49 ms | n/a / 4 MB |

Frontmatter parse (`frontmatter_parse`, 2026-10-06, `Frontmatter.parse/1`
end to end, min of 5, loaded dev box; "YamlElixir" is the old path, kept as
the fallback):

| Block | YamlElixir | Rust |
|---|---|---|
| 3 keys, 96 B | 885 us | 8 us |
| 10 keys, 262 B | 1,133 us | 25 us |
| 50 keys, 1.4 KB | 2,660 us | 126 us |

Rules, not a YAML parser (`yaml.rs`): it answers only for the common shape
(column-0 keys; one-line plain or quoted scalars, flow lists of them, block
lists of them; comments) and returns nil for anything else, which then goes
to YamlElixir. Floats decline too (Erlang's float printing is not
reproduced), as do hex/octal ints and a bare `+`/`-` (yamerl reads those as
0). YamlElixir stays the definition, and the test diffs both live instead of
pinning a golden file: `ENGRAM_FM_CASES=100000 mix test
test/engram/native/frontmatter_parse_test.exs` after touching the rules. A
REST write also parsed the merged block twice (OKF fields, parse_status);
it is parsed once now.

Title and tags (`note_title` and a since-deleted `note_tags`, same day): a typical 5 KB note
with frontmatter, 230 inline tags and code spans went from 3.55 ms to
0.34 ms per write (tags 3.5 ms to 0.3 ms; title alone ~10 us to ~47 us, the
fixed cost of a NIF call plus telemetry). 1 MB notes: 0.6-1 s down to
60-230 ms, native peak 2-5 MB. Rules ported as rules, not a YAML crate
(see `meta.rs` for why), pinned by an 8,012-case golden set.

`note_meta` (2026-10-06) returns both from one call, sharing the frontmatter
match and the CommonMark code ranges. Use it (`Helpers.extract_title_and_tags/2`)
wherever both are needed for the same text (REST upsert, CRDT merge,
checkpoint). Two calls -> one, min of 5 on a loaded box: 52 B 14 -> 10 us,
5 KB with an H1 title 152 -> 108 us, 5 KB with a frontmatter title
125 -> 99 us, 105 KB 3.6 -> 2.1-2.5 ms.

Telemetry consequence: write paths now emit `nif="note_meta"`, so the
`note_title` series only carries the remaining single-purpose callers
(rename re-title, markdown parser), and `note_tags` is gone (its only
caller, the test-facing `Helpers.extract_tags/1`, now reads `note_meta`).
A panel or alert filtered on those names undercounts writes; filter on
`note_meta`. None existed
in this repo or engram-infra when it changed (grepped 2026-10-06).

Language ID is NOT a candidate (measured 2026-10-06, #1877). The `lingua` hex
package already wraps lingua-rs; the ~6.5 ms per call is trigram scoring, and
building the detector costs ~0.1 ms. A port to `engram_native` (lingua-rs
1.7.2, one detector per node) ran 5.0-5.3 ms per 2K-char sample both before
and after, grew `engram_native.so` from 3.9 MB to 66 MB and the clean
release build from 41 s to 114 s. Dropped; the commit is on branch
`perf/sync-audit-lingua` if the memory-accounting win ever matters.

Each link is encoded as a BEAM term as soon as it is built, borrowing from
the note where it can, so the output never exists as a Rust copy. Only the
scrub REPORT stays in Elixir (`Helpers.report_scrub/1`): Rust counts the
percent escapes that decoded to invalid UTF-8, and Elixir emits the
telemetry and log for each.

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
3. **One telemetry shape for every NIF.** `Engram.Native.call/4` emits
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
- **Leak:** `Engram.NativeLeak.assert_no_leak(fun)`. A single warm-up call
  is not enough: the regex crate keeps a match cache per scheduler thread,
  allocated the first time a call lands on that thread, and a test process
  migrates between threads. That read as a ~670 KB "leak" on runs that leaked
  nothing. The helper warms every thread with concurrent calls, then asserts
  300 more calls leave `live_bytes()` unchanged.
- **Behaviour parity:** when porting, capture golden output from the Elixir
  code BEFORE deleting it, and keep its behaviour tests running against the
  NIF. The keyword port kept `tokenizer_test.exs` and `qdrant_sparse_test.exs`
  unchanged and added a 490-case golden set
  (`test/support/fixtures/keyword_tokens_golden.json`).
- **Rust-only tests** live in the crate (`cargo test`): the segmented-parse
  fuzz, panic guards, linear-time bounds. Time limits must only catch a
  complexity blowup (size the input so quadratic is >10x the limit and
  linear is <1/10 of it), never a slow runner. The counting allocator wraps
  the system allocator under `cargo test`, so memory tracking is tested too.

### Where each check runs

| Check | When | Blocks |
|---|---|---|
| `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test` (fuzz at 20k) | `unit-tests` job, every PR touching `native/` or Elixir source | merge (`unit-tests` is a required check) |
| Elixir NIF tests: golden sets, peak, leak, telemetry | `unit-tests`, same | merge |
| Fuzz at 2M cases x 3 seeds, `cargo audit` (RustSec) | nightly `native-deep` in `cron.yml`, or dispatch `task=native-deep` | nothing; alerts Discord on failure |
| Dependabot cargo updates | Wednesdays; patch+minor grouped and auto-merged once green | via the above |

`cargo audit` is nightly, not per-PR, so a newly published advisory does not
red unrelated PRs. Run the deep fuzz locally after touching the cut rules or
bumping pulldown-cmark: `ENGRAM_FUZZ_CASES=2000000 ENGRAM_FUZZ_SEED=7 cargo test --release segmented`.

## Scheduling

`schedule = "DirtyCpu"` on everything whose input size the caller controls,
EXCEPT small inputs on a hot path. The note parsers (`link_extract`,
`note_title`, `note_meta`) export a normal and a `_dirty_nif` variant, and
`Engram.Native` picks by size: up to 16 KB (`@inline_max`, well under 1 ms)
runs on the calling scheduler. A note write must not queue behind a long
keyword encode on the one dirty scheduler, and the hop alone cost ~20 us.
Telemetry metadata carries `dirty: true | false`.
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
  stub in `Engram.Native`, route it through `call/4` so it emits telemetry,
  and give it a peak-bound and a leak test.
- rustler: the crate and the hex package move together (0.38 both). The hex
  dep carries `override: true` because lingua pins an optional
  `rustler ~> 0.37.1` it only uses to force-build; lingua loads its
  precompiled NIF.
- rustfmt/clippy come from the CI rustup install (`--component`), not
  `rust-toolchain.toml`: the release Dockerfile copies the official image's
  minimal toolchain, and listing components there would make the image build
  download them.

## Gotchas found on the way

- **OTP's regex Unicode is from 2021.** OTP 27 bundles PCRE 8.45, whose
  Unicode tables disagree with current Unicode on ~39k codepoints. The Elixir
  tokenizer classified characters with them, and OTP 28 (PCRE2) would have
  changed tokens silently on upgrade. The Rust tokenizer uses current Unicode,
  pinned by `Cargo.lock`. A tokenizer change bumps `Engram.KeywordIndex`
  `@version`; `ReconcileEmbeddings` then rebuilds every note's keyword
  vectors in place, no Voyage spend and no operator step
  (`docs/context/index-version-self-heal.md`). Before bumping, wait until the WORKER tier
  is on the new release (`count by (role) (up{job="prometheus.scrape.engram_app"})`)
  so an older worker does not apply the old encoding.
- **`str::to_lowercase` applies Greek final sigma; `String.downcase` does
  not.** Lowercase per char (`flat_map(char::to_lowercase)`).
- **Stemmers come from a crate, not our repo:** `snowball_stemmers_rs`
  (generated by the official Snowball compiler, all 36 languages we use).
  `rust-stemmers` lacks nine languages LangDetect produces (ca, cs, eo, et,
  id, ga, lt, pl, eu); `waken_snowball` lacks cs and pl. The crate matched the
  old Elixir stemmer on all 490 golden cases. Prefer a maintained crate over
  vendored generated code; a stem change only needs the sparse re-index.
- **Index order is not part of the sparse contract.** Qdrant sorts indices on
  upsert and rejects duplicates, so the NIF emits sorted, merged indices.
- **pulldown-cmark keeps a node per inline item for its whole input.** That
  is 36x the input on a tight list and 73x on code-heavy markdown, worse than
  the regexes it replaced. `links.rs` parses in ~64 KB segments, cutting
  before a column-0 line that closes every open paragraph and container
  (after a blank line, or a list item, fence or ATX heading). pulldown-cmark
  then rejects a cut if a fenced or raw-HTML block runs to the segment's end,
  since a hand-written tracker for those cannot match it (it ends lines at a
  lone `\r` in one scanner and not in another). A rejected segment is re-cut
  just before that block when a cut may go there, else retried at double
  length: doubling alone grew to the whole note when candidate cuts kept
  landing inside fences (`# x` lines in code), and the heading pass peaked at
  7x a code-heavy note. The chunker reuses this pass (`links::segmented`).
  Text with no safe cut at all (a million `-` lines, setext runs, one long
  paragraph of `#tags`) is cut at a line anyway once 128 KB have no safe cut:
  pulldown-cmark's tree reached 72x such a note when parsed whole. A fuzz test asserts
  segmented == whole-document on generated markdown; run it at 2M cases
  after touching the cut rules.
- **Dense vector JSON prints the shortest f32, not the widened f64.** Qdrant
  stores f32, so `0.1` lands on the same f32 as `0.10000000149011612` did;
  a cargo test sweeps 2M bit patterns through f64 -> f32 to prove it. A test
  that reads the upserted JSON back must compare as f32.
- **`Jason.decode/1` keeps the FIRST of a repeated object key** (not the last,
  which is what `serde_json::Value` does). `json_decode` builds terms with a
  `DeserializeSeed` and de-duplicates first-wins. serde_json refuses nesting
  past 128 levels; Jason has no limit (Qdrant never nests that deep).
- **Run cargo tests with `--release`** (as CI does): the linearity tests in
  `links.rs`/`meta.rs` time themselves and fail in a debug build.
- **YamlElixir renames every `<<` key to a fresh `"<<N"`** (its merge-key
  handling), so it disagrees with itself run to run on such a block. A
  differential test must keep `<<` out of its generator.
- **A sensitive process cannot be call-counted.** `Crypto` sets
  `Process.flag(:sensitive, true)`, and from then on `:erlang.trace_pattern`
  `call_count` silently reads 0 for that process. A "this write parses N
  times" test does not work through a write path; count by reading the code.
- **This dev box cannot run Qdrant.** Its Xeon E5-2650 v2 lacks AVX2, and
  Qdrant 1.17 dies with SIGILL (exit 132) on collection create. Qdrant
  integration tests run in CI only.

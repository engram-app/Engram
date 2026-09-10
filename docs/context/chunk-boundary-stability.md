# Context Doc: Chunk Boundary Stability Under Edits

_Last verified: 2026-09-09_

## Status

Working, with a known bad shape. Measured 2026-09-09 while building the
chunk-reuse diff (#1592). No code change made — this doc records the
measurements so the follow-up is a decision rather than a rediscovery.

Sibling doc: `chunking-retrieval-strategy.md` covers chunking for *retrieval
quality*. This one covers chunk boundary *stability*, which only started
mattering once #1592 made unchanged chunks reusable.

## What This Is

`Engram.Indexing` reuses a chunk's vector when its `context_text` is unchanged
(#1592). That makes chunk **boundary stability** a cost driver: a chunk whose
text got re-packed is a chunk that must be re-embedded, even though the words
in it never changed.

`Engram.Parsers.Markdown.split_text/2` packs **space-separated words** greedily
to a 2048-byte budget, starting from the beginning of each heading section. The
budget decision depends on everything packed before it, so an edit can push the
tail word of its chunk into the next chunk, which pushes that chunk's tail
word onward, and so on **to the end of that heading section**.

Headings are what bound the cascade — a section break resets the packing.

## Measured Behaviour

Reuse rate for a **one-word edit** in a 10MB note (the `notes_controller.ex`
`@max_note_bytes` ceiling), ~5000 chunks:

| Note shape | chunks re-embedded | notes |
|---|---|---|
| Heading every ~20KB | **6** (0.12%) | edit position irrelevant |
| Heading every ~200KB | 39 (0.79%) | |
| No headings, paragraphs >1KB | **2** (0.04%) | edit position irrelevant |
| No headings, short paragraphs, edit at 75% | 1249 (25%) | |
| No headings, short paragraphs, edit at 25% | 3743 (75%) | cascade to end of doc |

Two regimes, and which one you land in is decided by paragraph size vs the
2048-byte budget:

- **One paragraph per chunk** (paragraphs bigger than ~1KB). The boundary rule
  is "a second one will not fit", which a few extra bytes cannot change.
  Nothing cascades, from any edit position.
- **Several paragraphs per chunk** (short paragraphs). The chunk is packed to
  the budget, so an edit spills the tail into the next chunk and the spill
  propagates to the end of the section.

Cascades are bounded by the section, not the document. Measured directly: with
a heading every ~1.4MB, an edit at 25% changed 182 chunks spanning indices
1250–1431 and stopped dead at the section break.

### Distribution across edit kinds

2MB heading-free note, ~291-byte paragraphs, 40 edit positions × 3 edit kinds
(edit / insert / delete a paragraph), 989 chunks total:

| splitter | chunks | vs today | median | p90 | worst | cascades (>10 chunks) |
|---|---|---|---|---|---|---|
| word-greedy (ships today) | 989 | — | 410 | 856 | 978 | 106/120 |
| paragraph + anchor k=4, min=512 | 1688 | +71% | 1 | 3 | 5 | **0/120** |
| paragraph + anchor k=8, min=512 | 1387 | +40% | 2 | 5 | 9 | **0/120** |
| paragraph + anchor k=8, min=1024 | 1204 | +22% | 2 | 16 | 38 | 27/120 |
| paragraph + anchor k=4, min=1536 | 1135 | +15% | 131 | 823 | 994 | 74/120 |

## Failed Approaches / Dead Ends

**Paragraph-granular packing alone.** Never split mid-paragraph, keep greedy
byte packing. 1130 chunks (+14%). Per edit kind, over 40 positions each:

| edit kind | median | p90 | worst | cascades |
|---|---|---|---|---|
| edit a paragraph | 1 | 1 | 1 | 0/40 |
| insert a paragraph | 1 | 1 | 1 | 0/40 |
| **delete a paragraph** | **592** | **1044** | **1118** | **40/40** |

Reads as a free win until you test deletes. Removing a paragraph frees space,
greedy packing pulls the next paragraph forward to fill it, and that repeats to
the end of the section. It survived the edit and insert cases only because a
~291-byte paragraph inside a 2048-byte chunk leaves ~292 bytes of slack, which
absorbs a small perturbation without displacing anything — a bigger insert
would cascade too. Do not adopt this on edit-only evidence.

**Tuning the anchor `min_chars` up to recover chunk count.** The inflation and
the resync are the same property. At `min=1536` the inflation drops to +15% and
cascades come back to 74/120, i.e. today's behaviour. There is no setting that
gives both.

**Measuring reuse with `MapSet` over a synthetic corpus of repeated
paragraphs.** The first pass at this produced 98.48% waste for every edit
position in the heading-free case, which is wrong. Identical paragraphs collapse
to one set element, so the intersection measured *distinct* reusable texts
rather than reusable chunks. Generate unique paragraph content and match with
multiplicity (`Enum.frequencies` + pop), the way `Indexing.plan_chunks/3` does.

## The Fix, If We Take It

Content-anchored paragraph breaks: only break between paragraphs, and start a
new chunk when the paragraph's own hash says "anchor"
(`rem(:erlang.phash2(paragraph), k) == 0`, gated on the accumulator already
reaching `min_chars`). Because the boundary depends on that one paragraph and
not on everything packed before it, the packing resyncs within a chunk or two
of any edit. This is the rsync/restic content-defined-chunking property.
Roughly 30 lines in `split_text/2`.

`k=8, min=512` is the measured sweet spot: median 2, worst 9, zero cascades,
+40% chunks.

**Gate it on section size.** +40% chunks means +40% Qdrant points, vector
storage, RAM, and first-index embed spend — permanently, for every note. Apply
anchored packing only inside sections over ~32KB. Below that, keep today's
packing byte-for-byte: no re-chunk, no re-embed, no inflation, and a cascade
inside a 32KB section costs at most ~16 chunks anyway. Then only the
pathological shape pays.

**Answer the empirical question first:** how many real notes have a >32KB
heading-free section? If it is a handful, this is not worth building.

## Gotchas

- `context_text` is `"folder > title > heading\n\ntext"`, and every
  `build_heading_path/2` clause prepends the title. So chunk reuse keys on the
  full embedded string, not the bare text — a title or folder change
  invalidates every chunk in the note by design.
- `char_start`/`char_end` on a chunk row are **section** offsets, so every
  sub-chunk of one section shares the same pair. They are not per-sub-chunk.
- The bad shape is not "large notes". It is "large notes with no headings and
  short paragraphs" — an exported chat log or a scraped dump, not prose. A
  10MB note with normal headings re-embeds 6 chunks out of 5000.
- Even the worst case is no worse than the pre-#1592 behaviour, which
  re-embedded every chunk on every edit unconditionally.

## Reproducing

The probes are not checked in; they are ~60 lines each and run against the real
parser with `mix run --no-start` (the app refuses to boot without
`ENCRYPTION_MASTER_KEY`, and `Markdown.parse/2` is pure so it does not need the
supervision tree).

Shape of the measurement:

```elixir
# Build a ~10MB body from UNIQUE paragraphs, optionally with headings every N.
# Apply a one-word edit / paragraph insert / paragraph delete at a given fraction.
# Parse both versions, then count reuse with multiplicity:
freq = Enum.frequencies(before_context_texts)
{reused, _} =
  Enum.reduce(after_context_texts, {0, freq}, fn t, {n, f} ->
    case Map.get(f, t, 0) do
      0 -> {n, f}
      c -> {n + 1, Map.put(f, t, c - 1)}
    end
  end)
```

Report `total - reused`, and print the *indices* of the changed chunks — the
index span is what distinguishes an isolated change from a cascade, and a bare
count hides it.

## References

- `lib/engram/parsers/markdown.ex` — `split_text/2`, `build_chunks/3`,
  `split_into_sections/2`
- `lib/engram/indexing.ex` — `plan_chunks/3` (the reuse diff)
- `lib/engram_web/controllers/notes_controller.ex:14` — `@max_note_bytes`, 10MB
- `docs/context/chunking-retrieval-strategy.md` — chunking for retrieval quality
- Issue #1592 — chunk reuse on the write path
- Issue #1594 — the follow-up: content-anchored boundaries, gated on section size

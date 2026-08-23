# Context Doc: identical frontmatter re-seed mints a second lineage

_Last verified: 2026-08-23_

## Status
Root-caused and fixed. Plugin PR engram-app/Engram-obsidian#464, e2e fence Engram#1454.

## Symptom, as reported
"We are duplicating the content of each note dozens of times." Then, after a
clean re-sync: server bytes exactly 2x the file on disk, on 224 of 316 notes.
Disk was never wrong.

## Why it resists diagnosis

Four traps, in the order they burned time:

1. **Opening a note heals it.** `Visit Notes Log (Revere Health).md` read 67,630
   bytes at 09:37 and 33,833 at 09:44, `version` 3 -> 6, because it was viewed in
   the web app at 09:42. Anything a human inspects has already converged, so
   "I don't see any duplication" and "the server holds it twice" are both true.
2. **The two copies do not always concatenate.** Where the insertions
   interleaved, text was still 2x but not a clean `X+X`. A
   "first half == second half" detector reported 17 of 60 doubled when the real
   answer was 224 of 316. Count Yjs clients, not bytes.
3. **`plain == crdt` proves nothing.** The `content` column is derived FROM the
   doc, so a server-side union produces that equality just as a client that
   uploaded doubled bytes would. This was used to wrongly conclude "the client
   sent doubled content".
4. **Every summary signal was correct.** Note count, room count and
   `genesis_seed` outcomes all matched a healthy run. Only the doc structure was
   wrong.

## The mechanical signature

Every affected note's stored Y.Doc holds exactly TWO clients, each with a clock
equal to half the final character count — the whole document inserted twice, once
per client. Read it with the state vector's leading varint (`e2e/helpers/lineage_probe.py`).

A healthy note written by one device has ONE client.

## Root cause

`applyFrontmatterInto` (`plugin/src/crdt/note-seed.ts`) guarded its MAP upsert
("only changed keys written") but replaced the ORDER array unconditionally:

```ts
if (arr.length > 0) arr.delete(0, arr.length);
if (order.length > 0) arr.insert(0, order);
```

Rewriting an identical key list changes nothing an observer can see, and a CRDT
still records the ops — which mints the writing device as a NEW client. A device
with no prior ops on that doc becomes a second lineage.

The chain that reaches it on a FIRST sync, where you would not expect any local
edit at all:

1. genesis seeds the note server-side from the disk bytes
2. the adopt awaits `flushFromCrdt`, which writes the doc's PROJECTION to disk
3. frontmatter does not round-trip byte-for-byte — `tags: [a, b]` comes back as a
   block list — so those bytes genuinely differ
4. Obsidian fires a real modify. `handleModify` deliberately SKIPS its
   recently-flushed guard for CRDT notes (`sync.ts`), on the stated premise that
   "the echo of a flush is naturally a no-op"
5. the echo reaches `applyLocalEdit` -> `seedContentInto` -> `applyFrontmatterInto`

Step 4's premise was true of the BODY (an unchanged body diffs to zero text ops)
and false of the frontmatter order. Instrumented on a real device:
`textLen 236->236` alongside a 31-byte LOCAL-origin update, three times over.

## Which notes are affected

Exactly those whose YAML does not survive parse + re-serialise. Measured 1:1 in
e2e: rewritten-on-disk <=> extra edit-class room <=> doubled lineage. Shapes that
break: inline arrays, quoted scalars, comments, irregular indentation, empty
values, numeric strings, blank lines inside the block. Shapes that survive: plain
block lists, nested maps, date scalars, no frontmatter at all.

## How to tell it apart from #1409's room storm

They co-occur and are NOT the same defect.

- Room storm (#1409, still open): `crdt_msg` allocates a server room per note.
  Measured 213 edit-class rooms for 316 notes. Costs memory, not correctness.
- This: a second lineage per note. Costs correctness.

The rooms are the visible symptom of the same cold sends that carry the second
lineage, which is why fixing the lineage bug also took edit-class rooms to zero
in `test_100`. It does NOT fix #1409 generally.

## Failed approaches (do not repeat)

- **Broad guard in `applyLocalEdit`**: `if (this.project(e) === diskContent) return diskContent;`
  Fixes the echo but breaks the re-sync-into-a-fresh-vault case — returning early
  skips the path that enrolls and pushes a doc the server vault has never seen,
  so the note reaches the server another way and forks anyway. `test_98` went
  from 0/25 to 65/65 doubled. The guard must be at the op-minting site, not at
  the function entry.
- **Unit reproduction**: three separate harnesses (double-seed with cleared
  baseline, genesis-then-local-edit, ProviderRegistry two-device relay) all
  PASSED against the buggy code. The transport has to be real; a harness that
  never connects buffers the second write and never ships it.
- **Client-ID count as a doubling test**: "2 clients" is normal in some states
  (checkpoint rebuild). It only discriminates when read per-note alongside the
  clock values.

## Reproducing

`e2e/tests/test_100_frontmatter_echo_single_lineage.py`. Round-trip-hostile YAML
shapes, one vault pass. Red against the unfixed plugin at 7/11 doubled + 7
edit-class rooms; green at 0 and 0.

Unit equivalent (1 second instead of 40): `plugin/tests/crdt/seed-gate.test.ts`,
"a second device re-seeding the SAME content adds no client" — reports
`after: 2` against the old code.

## Still open

- The disk rewrite itself (step 3) still happens and is currently by design: the
  CRDT stores frontmatter structurally and its projection is authoritative. It is
  a user-visible mutation of files the user did not edit. Not data loss.
- At least one file in the reporter's vault is doubled ON DISK, from an earlier
  sync that flushed doubled content before this was fixed. No repair sweep exists.

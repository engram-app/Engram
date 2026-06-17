import { merge as diff3Merge, diffIndices } from 'node-diff3'

export interface Merge3Result {
  text: string
  conflict: boolean
}

// A changed hunk on the base: `buffer1` is [start, length] in base lines,
// `buffer2` is [start, length] in the other side's lines. (node-diff3 shape.)
interface DiffHunk {
  buffer1: [number, number]
  buffer2: [number, number]
}

// Do two base-line ranges genuinely collide? Modifications collide on any
// shared base line. A pure insertion (length 0) is a point between lines: two
// insertions collide only at the SAME boundary (competing inserts); an
// insertion collides with a modification only when it falls STRICTLY inside the
// modified span — an insertion at the span's edge is adjacent, not a conflict.
//
// This is the crux: node-diff3's own `conflict` flag groups an edit and an
// adjacent insertion into one "conflict" region even though they touch disjoint
// base lines. Gating on real base-range overlap instead avoids nagging the user
// for benign concurrent edits.
function rangesCollide(a: [number, number], b: [number, number]): boolean {
  const [as, al] = a
  const [bs, bl] = b
  const ae = as + al
  const be = bs + bl
  const aIns = al === 0
  const bIns = bl === 0
  if (aIns && bIns) return as === bs
  if (aIns) return bs < as && as < be
  if (bIns) return as < bs && bs < ae
  return as < be && bs < ae
}

function anyCollision(aHunks: DiffHunk[], bHunks: DiffHunk[]): boolean {
  for (const a of aHunks) {
    for (const b of bHunks) {
      if (rangesCollide(a.buffer1, b.buffer1)) return true
    }
  }
  return false
}

// Apply two sets of base-disjoint hunks (one from local, one from remote) onto
// the base lines, producing the clean merged lines. Only valid when the hunks
// don't collide — guaranteed by the caller's `anyCollision` gate.
function applyDisjointHunks(
  base: string[],
  local: string[],
  remote: string[],
  aHunks: DiffHunk[],
  bHunks: DiffHunk[],
): string[] {
  const hunks = [
    ...aHunks.map((h) => ({ b1: h.buffer1, b2: h.buffer2, src: local })),
    ...bHunks.map((h) => ({ b1: h.buffer1, b2: h.buffer2, src: remote })),
  ].sort((x, y) => x.b1[0] - y.b1[0] || (x.b1[1] === 0 ? -1 : 1))

  const out: string[] = []
  let cursor = 0
  for (const h of hunks) {
    const [bStart, bLen] = h.b1
    const [xStart, xLen] = h.b2
    if (bStart > cursor) out.push(...base.slice(cursor, bStart))
    out.push(...h.src.slice(xStart, xStart + xLen))
    cursor = Math.max(cursor, bStart + bLen)
  }
  out.push(...base.slice(cursor))
  return out
}

// Line-level 3-way merge with TRUE-conflict detection. A conflict is reported
// only when local and remote changed OVERLAPPING base lines; non-overlapping
// edits (even adjacent ones) merge cleanly with no markers. On a real conflict
// we fall back to node-diff3's marker text so the caller can offer a manual
// "view merge" resolution.
export function merge3(base: string, local: string, remote: string): Merge3Result {
  // Identical sides agree — a 3-way merge of two equal sides is never a
  // conflict. Without this, two identical edits produce identical hunks over
  // the same base lines, which the collision gate (a range overlaps itself)
  // wrongly flags. Covers the self-echo case: a REST save's own note_changed
  // broadcast returns byte-identical content while baseRef is momentarily
  // stale, which otherwise raised a spurious conflict on every edit.
  if (local === remote) return { text: local, conflict: false }

  const O = base.split('\n')
  const A = local.split('\n')
  const B = remote.split('\n')
  const aHunks = diffIndices(O, A) as DiffHunk[]
  const bHunks = diffIndices(O, B) as DiffHunk[]

  if (anyCollision(aHunks, bHunks)) {
    const out = diff3Merge(A, O, B, { stringSeparator: '\n' })
    return { text: out.result.join('\n'), conflict: true }
  }

  return { text: applyDisjointHunks(O, A, B, aHunks, bHunks).join('\n'), conflict: false }
}

export interface Replacement {
  from: number
  to: number
  insert: string
}

// Minimal single-span replacement between oldStr and newStr: strip the common
// prefix and (non-overlapping) common suffix, replace only the middle. Applied
// as one CM change this leaves the selection untouched whenever the caret sits
// outside [from, to].
export function computeReplacement(oldStr: string, newStr: string): Replacement {
  let start = 0
  const max = Math.min(oldStr.length, newStr.length)
  while (start < max && oldStr[start] === newStr[start]) start++

  let endOld = oldStr.length
  let endNew = newStr.length
  while (endOld > start && endNew > start && oldStr[endOld - 1] === newStr[endNew - 1]) {
    endOld--
    endNew--
  }

  return { from: start, to: endOld, insert: newStr.slice(start, endNew) }
}

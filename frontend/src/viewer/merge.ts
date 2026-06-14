import { merge as diff3Merge } from 'node-diff3'

export interface Merge3Result {
  text: string
  conflict: boolean
}

// Line-level 3-way merge. node-diff3's `merge(a, o, b)` treats `a` as "mine"
// (local), `o` as the common ancestor (base), `b` as "theirs" (remote), and
// returns { conflict, result } where result already contains the git-style
// <<<<<<< / ======= / >>>>>>> markers on conflict.
export function merge3(base: string, local: string, remote: string): Merge3Result {
  const out = diff3Merge(local, base, remote, { stringSeparator: '\n' })
  return { text: out.result.join('\n'), conflict: out.conflict }
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

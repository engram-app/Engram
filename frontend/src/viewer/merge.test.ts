import { describe, expect, it } from 'vitest'
import { merge3, computeReplacement } from './merge'

describe('merge3', () => {
  it('merges non-overlapping remote + local edits cleanly', () => {
    const base = 'line1\nline2\nline3\n'
    const local = 'line1 EDITED\nline2\nline3\n' // local changed line1
    const remote = 'line1\nline2\nline3 EDITED\n' // remote changed line3
    const r = merge3(base, local, remote)
    expect(r.conflict).toBe(false)
    expect(r.text).toBe('line1 EDITED\nline2\nline3 EDITED\n')
  })

  it('flags an overlapping conflict and emits markers', () => {
    const base = 'hello\n'
    const local = 'hello local\n'
    const remote = 'hello remote\n'
    const r = merge3(base, local, remote)
    expect(r.conflict).toBe(true)
    expect(r.text).toContain('<<<<<<<')
    expect(r.text).toContain('>>>>>>>')
  })

  it('returns remote unchanged when local never diverged from base', () => {
    const base = 'a\nb\n'
    const r = merge3(base, base, 'a\nB\n')
    expect(r.conflict).toBe(false)
    expect(r.text).toBe('a\nB\n')
  })

  // The behavior the true-conflict gate fixes: node-diff3's own `conflict` flag
  // groups an edited line + an adjacent remote insertion into one "conflict"
  // even though they touch disjoint base lines.
  it('merges an edited line + an adjacent remote insertion cleanly (no markers)', () => {
    const base = '# Initial\n\noriginal text.'
    const local = '# Initial\n\noriginal text. draft-edit' // edits the last line
    const remote = '# Initial\n\noriginal text.\n\nremote-added-line' // appends after it
    const r = merge3(base, local, remote)
    expect(r.conflict).toBe(false)
    expect(r.text).toBe('# Initial\n\noriginal text. draft-edit\n\nremote-added-line')
    expect(r.text).not.toContain('<<<<<<<')
  })

  it('merges far-apart edits on the same document cleanly', () => {
    const base = 'A\nB\nC\nD\nE'
    const local = 'A2\nB\nC\nD\nE' // top
    const remote = 'A\nB\nC\nD\nE2' // bottom
    const r = merge3(base, local, remote)
    expect(r.conflict).toBe(false)
    expect(r.text).toBe('A2\nB\nC\nD\nE2')
  })

  it('flags competing insertions at the same boundary as a conflict', () => {
    const base = 'x\ny'
    const local = 'x\nMINE\ny'
    const remote = 'x\nTHEIRS\ny'
    const r = merge3(base, local, remote)
    expect(r.conflict).toBe(true)
    expect(r.text).toContain('MINE')
    expect(r.text).toContain('THEIRS')
  })

  it('does not flag a benign concurrent edit (local end, remote heading)', () => {
    const base = '# H\n\nintro.\n\norig.'
    const local = '# H\n\nintro.\n\norig. draft'
    const remote = '# Hremote\n\nintro.\n\norig.'
    const r = merge3(base, local, remote)
    expect(r.conflict).toBe(false)
    expect(r.text).toBe('# Hremote\n\nintro.\n\norig. draft')
  })
})

describe('computeReplacement', () => {
  it('returns the minimal changed span (mid-string edit)', () => {
    // "abcXYZdef" -> "abcQQdef": prefix "abc" (3), suffix "def" (3)
    expect(computeReplacement('abcXYZdef', 'abcQQdef')).toEqual({
      from: 3,
      to: 6,
      insert: 'QQ',
    })
  })

  it('returns a no-op span when strings are equal', () => {
    expect(computeReplacement('same', 'same')).toEqual({ from: 4, to: 4, insert: '' })
  })

  it('handles pure append', () => {
    expect(computeReplacement('abc', 'abcdef')).toEqual({ from: 3, to: 3, insert: 'def' })
  })
})

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

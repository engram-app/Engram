import { describe, expect, it } from 'vitest'
import { deriveActiveFolder } from './active-folder'

describe('deriveActiveFolder', () => {
  it('returns "" when not on a /note/ route', () => {
    expect(deriveActiveFolder('/settings/billing')).toBe('')
    expect(deriveActiveFolder('/')).toBe('')
  })

  it('returns "" when the note is at vault root', () => {
    expect(deriveActiveFolder('/note/A.md')).toBe('')
    expect(deriveActiveFolder('/note/Untitled.md')).toBe('')
  })

  it('returns the parent folder for nested notes', () => {
    expect(deriveActiveFolder('/note/foo/bar.md')).toBe('foo')
    expect(deriveActiveFolder('/note/foo/bar/baz.md')).toBe('foo/bar')
  })

  it('decodes percent-encoded path segments', () => {
    expect(deriveActiveFolder('/note/Has%20Space/file.md')).toBe('Has Space')
  })

  it('tolerates malformed percent-encoding', () => {
    expect(deriveActiveFolder('/note/foo%/bar.md')).toBe('foo%')
  })
})

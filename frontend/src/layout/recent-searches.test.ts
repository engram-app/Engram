import { beforeEach, describe, expect, it } from 'vitest'
import { pushRecent, readRecent } from './recent-searches'

describe('recent-searches', () => {
  beforeEach(() => window.localStorage.clear())

  it('returns [] when empty', () => expect(readRecent()).toEqual([]))

  it('pushes a query and reads it back', () => {
    pushRecent('hello')
    expect(readRecent()).toEqual(['hello'])
  })

  it('dedupes and moves to front', () => {
    pushRecent('aa'); pushRecent('bb'); pushRecent('aa')
    expect(readRecent()).toEqual(['aa', 'bb'])
  })

  it('caps at 8 entries', () => {
    for (let i = 0; i < 10; i++) pushRecent(`q${i}`)
    expect(readRecent()).toHaveLength(8)
    expect(readRecent()[0]).toBe('q9')
  })

  it('ignores queries shorter than 2 chars', () => {
    pushRecent('a')
    expect(readRecent()).toEqual([])
  })

  it('survives malformed localStorage', () => {
    window.localStorage.setItem('engram:recent-searches', '{not json')
    expect(readRecent()).toEqual([])
  })
})

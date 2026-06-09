import { describe, it, expect } from 'vitest'
import { formatItemId, parseItemId, ROOT_ID } from './types'

describe('item id helpers', () => {
  it('round-trips folder id', () => {
    expect(parseItemId(formatItemId({ kind: 'folder', id: 7 }))).toEqual({ kind: 'folder', id: 7 })
  })

  it('round-trips note id', () => {
    expect(parseItemId(formatItemId({ kind: 'note', id: 42 }))).toEqual({ kind: 'note', id: 42 })
  })

  it('parseItemId rejects unknown prefix', () => {
    expect(() => parseItemId('x:1')).toThrow()
  })

  it('root sentinel returns kind: root', () => {
    expect(parseItemId(ROOT_ID)).toEqual({ kind: 'root' })
  })
})

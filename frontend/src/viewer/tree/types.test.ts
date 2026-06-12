import { describe, it, expect } from 'vitest'
import { formatItemId, parseItemId, ROOT_ID } from './types'

describe('item id helpers', () => {
  it('round-trips folder id', () => {
    expect(parseItemId(formatItemId({ kind: 'folder', id: '01923a4b-cdef-7000-89ab-cdef01234567' }))).toEqual({ kind: 'folder', id: '01923a4b-cdef-7000-89ab-cdef01234567' })
  })

  it('round-trips note id', () => {
    expect(parseItemId(formatItemId({ kind: 'note', id: '01923a4b-cdef-7000-89ab-cdef01234567' }))).toEqual({ kind: 'note', id: '01923a4b-cdef-7000-89ab-cdef01234567' })
  })

  it('parseItemId rejects unknown prefix', () => {
    expect(() => parseItemId('x:1')).toThrow()
  })

  it('root sentinel returns kind: root', () => {
    expect(parseItemId(ROOT_ID)).toEqual({ kind: 'root' })
  })
})

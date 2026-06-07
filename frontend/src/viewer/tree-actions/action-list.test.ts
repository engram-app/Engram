import { describe, expect, it } from 'vitest'
import { actionsFor, type Action } from './action-list'

describe('actionsFor', () => {
  it('file actions: rename, move, duplicate, copy-wikilink, delete', () => {
    const ids = actionsFor({ kind: 'file' }).map((a) => a.id)
    expect(ids).toEqual(['rename', 'move', 'duplicate', 'copy-wikilink', 'delete'])
  })

  it('folder actions: rename, move, delete (no duplicate, no wikilink)', () => {
    const ids = actionsFor({ kind: 'folder' }).map((a) => a.id)
    expect(ids).toEqual(['rename', 'move', 'delete'])
  })
})

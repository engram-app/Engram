import { describe, it, expect } from 'vitest'
import { isSyntheticFolderId, synthesizeFolders } from './synthesize-folders'
import type { AttachmentSummary, Folder } from '../../api/queries'

const att = (path: string): AttachmentSummary => ({
  id: `att:${path}`, path, mime_type: 'image/png', size_bytes: 1, mtime: 0, updated_at: '',
})

describe('synthesizeFolders', () => {
  it('returns real folders unchanged when every attachment dir exists', () => {
    const real: Folder[] = [{ id: 'r1', parent_id: null, name: 'img', count: 2 }]
    const out = synthesizeFolders(real, [att('img/a.png')])
    expect(out).toHaveLength(1)
    expect(out[0]).toMatchObject({ id: 'r1', name: 'img' })
  })

  it('synthesizes a folder that exists only via an attachment', () => {
    const out = synthesizeFolders([], [att('pics/a.png')])
    const pics = out.find((f) => f.name === 'pics')
    expect(pics).toMatchObject({ id: 'syn:pics', parent_id: null, name: 'pics' })
  })

  it('synthesizes the full ancestor chain with correct parent ids', () => {
    const out = synthesizeFolders([], [att('a/b/c.png')])
    const a = out.find((f) => f.name === 'a')
    const b = out.find((f) => f.name === 'a/b')
    expect(a).toMatchObject({ id: 'syn:a', parent_id: null })
    expect(b).toMatchObject({ id: 'syn:a/b', parent_id: 'syn:a' })
  })

  it('links a synthetic child under an existing real parent', () => {
    const real: Folder[] = [{ id: 'r1', parent_id: null, name: 'docs', count: 0 }]
    const out = synthesizeFolders(real, [att('docs/sub/x.pdf')])
    const sub = out.find((f) => f.name === 'docs/sub')
    expect(sub).toMatchObject({ id: 'syn:docs/sub', parent_id: 'r1' })
  })

  it('root-level attachments add no folders', () => {
    const out = synthesizeFolders([], [att('cover.png')])
    expect(out).toHaveLength(0)
  })

  it('does not duplicate a synthetic dir shared by two attachments', () => {
    const out = synthesizeFolders([], [att('p/a.png'), att('p/b.png')])
    expect(out.filter((f) => f.name === 'p')).toHaveLength(1)
  })

  it('synthesizes missing ancestors from a note-folder path (no attachments)', () => {
    // Backend returns only the leaf folder that holds notes; ancestors are absent.
    const real: Folder[] = [{ id: 'syn:a/b/c', parent_id: null, name: 'a/b/c', count: 3 }]
    const out = synthesizeFolders(real, [])
    const a = out.find((f) => f.name === 'a')
    const ab = out.find((f) => f.name === 'a/b')
    const abc = out.find((f) => f.name === 'a/b/c')
    expect(a).toMatchObject({ parent_id: null })
    expect(ab).toMatchObject({ parent_id: a!.id })
    expect(abc).toMatchObject({ id: 'syn:a/b/c', parent_id: ab!.id })
  })

  it('derives parent_id by path for flat note-folders the backend returned unparented', () => {
    // Both come back parent_id:null (derived folders); x/y must nest under x.
    const real: Folder[] = [
      { id: 'syn:x', parent_id: null, name: 'x', count: 1 },
      { id: 'syn:x/y', parent_id: null, name: 'x/y', count: 2 },
    ]
    const out = synthesizeFolders(real, [])
    const x = out.find((f) => f.name === 'x')
    const xy = out.find((f) => f.name === 'x/y')
    expect(xy).toMatchObject({ parent_id: x!.id })
  })

  it('isSyntheticFolderId distinguishes synthesized rows from real uuids', () => {
    const syn = synthesizeFolders([], [att('pics/a.png')]).find((f) => f.name === 'pics')
    expect(isSyntheticFolderId(syn!.id)).toBe(true)
    expect(isSyntheticFolderId('a1b2c3d4-0000-0000-0000-000000000000')).toBe(false)
  })
})

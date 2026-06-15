import { describe, it, expect } from 'vitest'
import { synthesizeFolders } from './synthesize-folders'
import type { AttachmentSummary, Folder } from '../../api/queries'

const att = (path: string): AttachmentSummary => ({
  path, mime_type: 'image/png', size_bytes: 1, mtime: 0, updated_at: '',
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
})

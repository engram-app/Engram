import { describe, it, expect, vi } from 'vitest'
import { QueryClient } from '@tanstack/react-query'
import { buildLoader, type SortKey } from './loader'
import type { Folder, NoteSummary } from '../../api/queries'

const folders: Folder[] = [
  { id: 1, parent_id: null, name: 'Projects', count: 2 },
  { id: 2, parent_id: 1, name: 'Projects/Engram', count: 1 },
]

const notesByFolder: Record<number, NoteSummary[]> = {
  1: [
    {
      id: 100,
      path: 'Projects/a.md',
      title: 'a',
      folder: 'Projects',
      tags: [],
      version: 1,
      mtime: '2026-01-01T00:00:00Z',
      created_at: '2026-01-01T00:00:00Z',
      updated_at: '2026-01-01T00:00:00Z',
    },
  ],
  2: [
    {
      id: 200,
      path: 'Projects/Engram/b.md',
      title: 'b',
      folder: 'Projects/Engram',
      tags: [],
      version: 1,
      mtime: '2026-01-02T00:00:00Z',
      created_at: '2026-01-02T00:00:00Z',
      updated_at: '2026-01-02T00:00:00Z',
    },
  ],
}

function makeQc(): QueryClient {
  const qc = new QueryClient()
  qc.setQueryData(['folder-notes-by-id', 'v', 1], notesByFolder[1])
  qc.setQueryData(['folder-notes-by-id', 'v', 2], notesByFolder[2])
  return qc
}

describe('buildLoader', () => {
  it('root returns top-level folders + any root notes, sorted', () => {
    const loader = buildLoader({ folders, qc: makeQc(), vaultId: 'v', sort: 'name-asc' as SortKey, rootNotes: [] })
    const children = loader.getChildren('root')
    expect(children.map(c => c.itemId)).toEqual(['f:1'])
  })

  it('folder children return child folders first then notes', () => {
    const loader = buildLoader({ folders, qc: makeQc(), vaultId: 'v', sort: 'name-asc' as SortKey, rootNotes: [] })
    const children = loader.getChildren('f:1')
    expect(children.map(c => c.itemId)).toEqual(['f:2', 'n:100'])
  })

  it('cache miss returns [] and triggers fetch via real fetcher', () => {
    const qc = new QueryClient()
    qc.setQueryData(['folder-notes-by-id', 'v', 1], notesByFolder[1])
    // No data for folder id 2.
    const fetchFolderNotes = vi.fn(() => Promise.resolve<NoteSummary[]>([]))
    const fetchSpy = vi.spyOn(qc, 'fetchQuery')
    const loader = buildLoader({
      folders,
      qc,
      vaultId: 'v',
      sort: 'name-asc' as SortKey,
      rootNotes: [],
      fetchFolderNotes,
    })
    const children = loader.getChildren('f:2')
    // Child folders for f:2 = none in fixture; notes not cached → returns []
    expect(children).toEqual([])
    expect(fetchSpy).toHaveBeenCalledWith(expect.objectContaining({
      queryKey: ['folder-notes-by-id', 'v', 2],
    }))
    // The queryFn passed to fetchQuery must invoke our real fetcher with
    // the folder id — guards against regressing back to a dummy queryFn.
    const call = fetchSpy.mock.calls[0]?.[0] as unknown as { queryFn: (ctx?: unknown) => Promise<NoteSummary[]> }
    void call.queryFn()
    expect(fetchFolderNotes).toHaveBeenCalledWith(2)
  })

  it('cache miss without fetcher returns [] and does not fetch', () => {
    const qc = new QueryClient()
    const fetchSpy = vi.spyOn(qc, 'fetchQuery')
    const loader = buildLoader({ folders, qc, vaultId: 'v', sort: 'name-asc' as SortKey, rootNotes: [] })
    const children = loader.getChildren('f:2')
    expect(children).toEqual([])
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('getItem returns shaped TreeItem for a folder id', () => {
    const loader = buildLoader({ folders, qc: makeQc(), vaultId: 'v', sort: 'name-asc' as SortKey, rootNotes: [] })
    expect(loader.getItem('f:1')?.item).toMatchObject({ kind: 'folder', id: 1, path: 'Projects', name: 'Projects' })
  })

  it('note sort by modified-desc', () => {
    const loader = buildLoader({ folders, qc: makeQc(), vaultId: 'v', sort: 'modified-desc' as SortKey, rootNotes: [] })
    const children = loader.getChildren('f:1')
    // Notes only; folders sorted by name. Here just 1 note.
    expect(children.map(c => c.itemId)).toContain('n:100')
  })
})

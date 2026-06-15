import { describe, it, expect, vi } from 'vitest'
import { QueryClient } from '@tanstack/react-query'
import { buildLoader, type SortKey } from './loader'
import type { AttachmentSummary, Folder, NoteSummary } from '../../api/queries'

const folders: Folder[] = [
  { id: '1', parent_id: null, name: 'Projects', count: 2 },
  { id: '2', parent_id: '1', name: 'Projects/Engram', count: 1 },
]

const notesByFolder: Record<string, NoteSummary[]> = {
  '1': [
    {
      id: '100',
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
  '2': [
    {
      id: '200',
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

const rootNote: NoteSummary = {
  id: '300',
  path: 'top.md',
  title: 'top',
  folder: '',
  tags: [],
  version: 1,
  mtime: '2026-01-03T00:00:00Z',
  created_at: '2026-01-03T00:00:00Z',
  updated_at: '2026-01-03T00:00:00Z',
}

function makeQc(): QueryClient {
  const qc = new QueryClient()
  qc.setQueryData(['folder-notes-by-id', 'v', '1'], notesByFolder['1'])
  qc.setQueryData(['folder-notes-by-id', 'v', '2'], notesByFolder['2'])
  return qc
}

// Standalone qc for attachment tests (no pre-seeded folder notes)
const qc = new QueryClient()

const att = (path: string): AttachmentSummary => ({
  path, mime_type: path.endsWith('.pdf') ? 'application/pdf' : 'image/png',
  size_bytes: 1, mtime: 0, updated_at: '',
})

it('lists root attachments under ROOT', () => {
  const loader = buildLoader({
    folders: [], qc, vaultId: 'v1', sort: 'name-asc',
    attachments: [att('cover.png')],
  })
  const kids = loader.getChildren('root')
  const a = kids.find((k) => k.item.kind === 'attachment')
  expect(a?.item).toMatchObject({ kind: 'attachment', path: 'cover.png', mime: 'image/png' })
  expect(a?.itemId).toBe('a:cover.png')
})

it('buckets an attachment under its folder', () => {
  const folders = [{ id: 'f1', parent_id: null, name: 'img', count: 0 }]
  const loader = buildLoader({
    folders, qc, vaultId: 'v1', sort: 'name-asc',
    attachments: [att('img/a.png')],
  })
  qc.setQueryData(['folder-notes-by-id', 'v1', 'f1'], [])
  const kids = loader.getChildren('f:f1')
  expect(kids.map((k) => k.item.kind)).toContain('attachment')
  const a = kids.find((k) => k.item.kind === 'attachment')
  expect(a?.item).toMatchObject({ path: 'img/a.png' })
})

it('does not leak a subfolder attachment into its parent', () => {
  const folders = [
    { id: 'f1', parent_id: null, name: 'img', count: 0 },
    { id: 'f2', parent_id: 'f1', name: 'img/sub', count: 0 },
  ]
  const loader = buildLoader({
    folders, qc, vaultId: 'v1', sort: 'name-asc',
    attachments: [att('img/sub/deep.png')],
  })
  qc.setQueryData(['folder-notes-by-id', 'v1', 'f1'], [])
  const kids = loader.getChildren('f:f1')
  expect(kids.find((k) => k.item.kind === 'attachment')).toBeUndefined()
})

it('shows attachments even while folder notes are still loading (cache miss)', () => {
  const folders = [{ id: 'f1', parent_id: null, name: 'img', count: 0 }]
  const loader = buildLoader({
    folders, qc, vaultId: 'v1', sort: 'name-asc',
    attachments: [att('img/a.png')],
    // no fetchFolderNotes, no seeded cache -> noteChildItems returns null
  })
  const freshQc = new QueryClient()
  const loaderFresh = buildLoader({
    folders, qc: freshQc, vaultId: 'v1', sort: 'name-asc',
    attachments: [att('img/a.png')],
  })
  const kids = loaderFresh.getChildren('f:f1')
  expect(kids.find((k) => k.item.kind === 'attachment')).toBeDefined()
})

describe('buildLoader', () => {
  it('root returns top-level folders + root notes from the by-id root cache, sorted', () => {
    const qc = makeQc()
    // Root notes live in the one id-keyed cache under the 'root' sentinel.
    qc.setQueryData(['folder-notes-by-id', 'v', 'root'], [rootNote])
    const loader = buildLoader({ folders, qc, vaultId: 'v', sort: 'name-asc' as SortKey })
    const children = loader.getChildren('root')
    expect(children.map(c => c.itemId)).toEqual(['f:1', 'n:300'])
  })

  it('root with no cached root list returns folders only', () => {
    const loader = buildLoader({ folders, qc: makeQc(), vaultId: 'v', sort: 'name-asc' as SortKey })
    const children = loader.getChildren('root')
    expect(children.map(c => c.itemId)).toEqual(['f:1'])
  })

  it('folder children return child folders first then notes', () => {
    const loader = buildLoader({ folders, qc: makeQc(), vaultId: 'v', sort: 'name-asc' as SortKey })
    const children = loader.getChildren('f:1')
    expect(children.map(c => c.itemId)).toEqual(['f:2', 'n:100'])
  })

  it('cache miss returns [] and triggers fetch via real fetcher', () => {
    const qc = new QueryClient()
    qc.setQueryData(['folder-notes-by-id', 'v', '1'], notesByFolder['1'])
    // No data for folder id 2.
    const fetchFolderNotes = vi.fn(() => Promise.resolve<NoteSummary[]>([]))
    const fetchSpy = vi.spyOn(qc, 'fetchQuery')
    const loader = buildLoader({
      folders,
      qc,
      vaultId: 'v',
      sort: 'name-asc' as SortKey,
      fetchFolderNotes,
    })
    const children = loader.getChildren('f:2')
    // Child folders for f:2 = none in fixture; notes not cached → returns []
    expect(children).toEqual([])
    expect(fetchSpy).toHaveBeenCalledWith(expect.objectContaining({
      queryKey: ['folder-notes-by-id', 'v', '2'],
    }))
    // The queryFn passed to fetchQuery must invoke our real fetcher with
    // the folder id — guards against regressing back to a dummy queryFn.
    const call = fetchSpy.mock.calls[0]?.[0] as unknown as { queryFn: (ctx?: unknown) => Promise<NoteSummary[]> }
    void call.queryFn()
    expect(fetchFolderNotes).toHaveBeenCalledWith('2')
  })

  it('root cache miss triggers a fetch for the root sentinel', () => {
    const qc = new QueryClient()
    const fetchFolderNotes = vi.fn(() => Promise.resolve<NoteSummary[]>([]))
    const fetchSpy = vi.spyOn(qc, 'fetchQuery')
    const loader = buildLoader({ folders, qc, vaultId: 'v', sort: 'name-asc' as SortKey, fetchFolderNotes })
    loader.getChildren('root')
    expect(fetchSpy).toHaveBeenCalledWith(expect.objectContaining({
      queryKey: ['folder-notes-by-id', 'v', 'root'],
    }))
    const call = fetchSpy.mock.calls[0]?.[0] as unknown as { queryFn: () => Promise<NoteSummary[]> }
    void call.queryFn()
    expect(fetchFolderNotes).toHaveBeenCalledWith('root')
  })

  it('cache miss without fetcher returns [] and does not fetch', () => {
    const qc = new QueryClient()
    const fetchSpy = vi.spyOn(qc, 'fetchQuery')
    const loader = buildLoader({ folders, qc, vaultId: 'v', sort: 'name-asc' as SortKey })
    const children = loader.getChildren('f:2')
    expect(children).toEqual([])
    expect(fetchSpy).not.toHaveBeenCalled()
  })

  it('getItem returns shaped TreeItem for a folder id', () => {
    const loader = buildLoader({ folders, qc: makeQc(), vaultId: 'v', sort: 'name-asc' as SortKey })
    expect(loader.getItem('f:1')?.item).toMatchObject({ kind: 'folder', id: '1', path: 'Projects', name: 'Projects' })
  })

  it('note sort by modified-desc', () => {
    const loader = buildLoader({ folders, qc: makeQc(), vaultId: 'v', sort: 'modified-desc' as SortKey })
    const children = loader.getChildren('f:1')
    // Notes only; folders sorted by name. Here just 1 note.
    expect(children.map(c => c.itemId)).toContain('n:100')
  })
})

import React from 'react'
import { afterEach, beforeEach, describe, expect, expectTypeOf, it, vi } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

vi.mock('sonner', () => ({
  toast: {
    error: vi.fn(),
    success: vi.fn(),
    info: vi.fn(),
  },
}))

// queries.ts pulls useNavigate from react-router (useCreateNote). Stub it so
// the hooks render without a Router in these unit tests.
vi.mock('react-router', () => ({ useNavigate: () => () => {} }))

// Pin the active vault id so cache keys are deterministic for the
// optimistic-update tests below. The hook reads from a module-scoped
// store + localStorage; setting localStorage before module import is
// brittle, so we mock the hook directly.
vi.mock('./active-vault', async () => {
  const actual = await vi.importActual<typeof import('./active-vault')>('./active-vault')
  return { ...actual, useActiveVaultId: () => '42' }
})

const { get, post, del } = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  del: vi.fn(),
}))
vi.mock('./client', async () => {
  const actual = await vi.importActual<typeof import('./client')>('./client')
  return {
    ...actual,
    api: { get, post, patch: vi.fn(), del },
    setTokenGetter: vi.fn(),
  }
})

import { ApiError } from './client'
import {
  type Folder,
  type Note,
  useAcceptTerms,
  useAttachments,
  useBatchDeleteAttachments,
  useBatchDeleteFolders,
  useBatchDeleteNotes,
  useBatchMoveAttachments,
  useBatchMoveFolders,
  useBatchMoveNotes,
  useCancelSubscription,
  useConfirmPlanChange,
  useCreateNote,
  useDeleteFolder,
  useDeleteNote,
  useDuplicateNote,
  useFolderNotesById,
  useFolders,
  useNote,
  usePlanChangePreview,
  useRenameAttachment,
  useRenameFolder,
  useRenameNote,
  useReverseCancel,
  useSearch,
} from './queries'

let qc: QueryClient

beforeEach(() => {
  get.mockReset()
  post.mockReset()
  del.mockReset()
  qc = new QueryClient()
})

afterEach(() => {
  qc.clear()
})

function wrapper({ children }: { children: React.ReactNode }) {
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('useAcceptTerms', () => {
  it('awaits onboarding/status refetch before mutateAsync resolves', async () => {
    // Seed the cache so invalidate triggers a refetch instead of a no-op.
    qc.setQueryData(['onboarding', 'status'], { next_step: 'agreement', enabled: true })

    let invalidateResolved = false
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries').mockImplementation(async () => {
      await new Promise((r) => setTimeout(r, 20))
      invalidateResolved = true
    })

    post.mockResolvedValue({ version: 'v2.0', accepted_at: '2026-06-01T00:00:00Z' })

    const { result } = renderHook(() => useAcceptTerms(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        tos_version: 'v2.0',
        tos_hash: 'th',
        privacy_version: 'v1.0',
        privacy_hash: 'ph',
      })
    })

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['onboarding', 'status'] })
    // If onSuccess fires-and-forgets, this would still be false when mutateAsync resolves
    // and the user would be navigated with a stale cache (bug: double-accept).
    expect(invalidateResolved).toBe(true)
  })
})

describe('inline billing mutations', () => {
  it('useCancelSubscription POSTs and invalidates billing caches', async () => {
    post.mockResolvedValue({ scheduled_change: { effective_at: '2026-07-01T00:00:00Z' } })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useCancelSubscription(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync()
    })

    expect(post).toHaveBeenCalledWith('/billing/cancel-subscription')
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['billing', 'status'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['billing', 'subscription'] })
  })

  it('useReverseCancel POSTs and invalidates billing caches', async () => {
    post.mockResolvedValue({ scheduled_change: null })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useReverseCancel(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync()
    })

    expect(post).toHaveBeenCalledWith('/billing/reverse-cancel')
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['billing', 'status'] })
  })

  it('useConfirmPlanChange forwards target_price_id and invalidates caches', async () => {
    post.mockResolvedValue({ transaction_id: 'txn_xyz' })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useConfirmPlanChange(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync('pri_new')
    })

    expect(post).toHaveBeenCalledWith('/billing/plan-change/confirm', {
      target_price_id: 'pri_new',
    })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['billing', 'subscription'] })
  })

  it('usePlanChangePreview stays disabled until a target is selected', () => {
    const { result } = renderHook(() => usePlanChangePreview(null), { wrapper })
    // No fetch happens for null target — query is disabled.
    expect(post).not.toHaveBeenCalled()
    expect(result.current.fetchStatus).toBe('idle')
  })
})

describe('useNote by id', () => {
  it('fetches /notes/by-id/:id and caches by id', async () => {
    get.mockResolvedValue({
      id: '42',
      path: 'a.md',
      title: 'A',
      folder: '',
      tags: [],
      version: 1,
      content: '# A',
      mtime: 's',
      created_at: 's',
      updated_at: 's',
    } as Note)
    const { result } = renderHook(() => useNote('42'), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(get).toHaveBeenCalledWith('/notes/by-id/42')
  })

  it('is disabled when id is null', () => {
    const { result } = renderHook(() => useNote(null), { wrapper })
    expect(result.current.fetchStatus).toBe('idle')
    expect(get).not.toHaveBeenCalled()
  })
})

describe('useRenameNote', () => {
  it('POSTs /notes/rename and invalidates folders + folder lists + old note key', async () => {
    post.mockResolvedValue({ renamed: true, old_path: 'a/x.md', new_path: 'b/y.md' })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useRenameNote(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ old_path: 'a/x.md', new_path: 'b/y.md' })
    })

    expect(post).toHaveBeenCalledWith('/notes/rename', {
      old_path: 'a/x.md',
      new_path: 'b/y.md',
    })
    // onSettled scopes invalidation by vault — broader keys would
    // touch other vaults' caches needlessly.
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['note', '42'] })
  })

  it('surfaces 409 as ApiError', async () => {
    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useRenameNote(), { wrapper })
    await expect(
      result.current.mutateAsync({ old_path: 'a.md', new_path: 'b.md' }),
    ).rejects.toMatchObject({ status: 409 })
  })
})

describe('useRenameFolder', () => {
  it('POSTs /folders/rename and invalidates folders + folder lists', async () => {
    post.mockResolvedValue({ renamed: true, old_path: 'a', new_path: 'b', count: 3 })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useRenameFolder(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ old_path: 'a', new_path: 'b' })
    })

    expect(post).toHaveBeenCalledWith('/folders/rename', {
      old_path: 'a',
      new_path: 'b',
    })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', '42'] })
  })

  it('surfaces 409 as ApiError', async () => {
    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useRenameFolder(), { wrapper })
    await expect(
      result.current.mutateAsync({ old_path: 'a', new_path: 'b' }),
    ).rejects.toMatchObject({ status: 409 })
  })
})

describe('useDeleteNote', () => {
  it('DELETEs /notes/by-id/:id and invalidates folders + folder list + removes note', async () => {
    del.mockResolvedValue({ deleted: true })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')
    const removeSpy = vi.spyOn(qc, 'removeQueries')

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ id: '42', path: 'foo bar/x y.md' })
    })

    // URL is keyed on the note id — server is the source of truth for
    // path/folder lookups, so the client just supplies the id.
    expect(del).toHaveBeenCalledWith('/notes/by-id/42')
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', '42'] })
    // The optimistic onMutate removes the note's body cache, keyed by id.
    expect(removeSpy).toHaveBeenCalledWith({ queryKey: ['note', '42', '42'] })
  })

  it('surfaces backend errors as ApiError', async () => {
    del.mockRejectedValue(new ApiError(404, 'not found'))

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    await expect(
      result.current.mutateAsync({ id: '7', path: 'gone.md' }),
    ).rejects.toMatchObject({
      status: 404,
    })
  })
})

describe('useDuplicateNote', () => {
  it('GETs source content then POSTs new note at new_path and invalidates listings', async () => {
    get.mockResolvedValue({
      path: 'a.md',
      title: 'a',
      folder: '',
      tags: [],
      version: 1,
      mtime: '',
      created_at: '',
      updated_at: '',
      content: 'hello world',
    })
    post.mockResolvedValue({ note: { path: 'a (copy).md', content: 'hello world' } })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useDuplicateNote(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ src_path: 'a.md', new_path: 'a (copy).md' })
    })

    expect(get).toHaveBeenCalledWith('/notes/a.md')
    expect(post).toHaveBeenCalledWith(
      '/notes',
      expect.objectContaining({ path: 'a (copy).md', content: 'hello world' }),
    )
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', '42'] })
  })

  it('surfaces 409 from POST as ApiError so callers can toast', async () => {
    get.mockResolvedValue({ content: 'x' })
    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useDuplicateNote(), { wrapper })
    await expect(
      result.current.mutateAsync({ src_path: 'a.md', new_path: 'a (copy).md' }),
    ).rejects.toMatchObject({ status: 409 })
  })

  it('mirrors the optimistic placeholder into the tree by-id list', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [{ id: 'f9', parent_id: null, name: 'dst', count: 1 }],
    })
    seedFolderNotesById('f9', [{ id: 'a', path: 'dst/a.md' }])
    qc.setQueryData(['folderNotes', '42', 'dst'], { notes: [] })

    get.mockResolvedValue({ content: 'x' })
    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useDuplicateNote(), { wrapper })
    act(() => {
      result.current.mutate({ src_path: 'dst/a.md', new_path: 'dst/a copy.md' })
    })

    await waitFor(() => {
      const byId = qc.getQueryData<Array<{ id: string; path: string }>>([
        'folder-notes-by-id',
        '42',
        'f9',
      ])
      expect(byId?.some((n) => n.path === 'dst/a copy.md')).toBe(true)
    })

    resolvePost({
      note: {
        id: 'real',
        path: 'dst/a copy.md',
        title: 'a copy',
        folder: 'dst',
        tags: [],
        version: 1,
        mtime: '',
        created_at: '',
        updated_at: '',
      },
    })

    // After success the placeholder id is swapped for the server id.
    await waitFor(() => {
      const byId = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', 'f9'])
      expect(byId?.some((n) => n.id === 'real')).toBe(true)
    })
  })
})

describe('useDeleteFolder', () => {
  it('DELETEs encoded folder path and invalidates folders + folder lists', async () => {
    del.mockResolvedValue({ deleted: true })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useDeleteFolder(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ path: 'my folder/sub' })
    })

    expect(del).toHaveBeenCalledWith('/folders/my%20folder/sub')
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', '42'] })
  })

  it('surfaces backend errors as ApiError', async () => {
    del.mockRejectedValue(new ApiError(404, 'not found'))

    const { result } = renderHook(() => useDeleteFolder(), { wrapper })
    await expect(result.current.mutateAsync({ path: 'gone' })).rejects.toMatchObject({
      status: 404,
    })
  })
})

// ── Optimistic-update behaviour ──────────────────────────────
//
// These tests don't assert on network calls — that's the responsibility
// of the per-mutation specs above. They lock in the snappy-UI contract:
// caches mutate synchronously on `onMutate`, and `onError` restores the
// pre-mutation snapshot so a rejected request leaves no visible trace.

function seedFolderNotes(
  folder: string,
  notes: Array<Partial<{ id: string; path: string; title: string }>>,
) {
  qc.setQueryData(['folderNotes', '42', folder], {
    notes: notes.map((n, i) => ({
      id: n.id ?? String(i + 1),
      path: n.path ?? '',
      title: n.title ?? '',
      folder,
      tags: [],
      version: 1,
      mtime: '',
      created_at: '',
      updated_at: '',
    })),
  })
}

function seedFolders(folders: Array<{ name: string; count: number }>) {
  qc.setQueryData(['folders', '42'], { folders })
}

describe('optimistic rename note', () => {
  it('removes the note from the old folder cache and inserts into the new folder before the network resolves', async () => {
    seedFolderNotes('a', [{ path: 'a/x.md', title: 'X' }])
    seedFolderNotes('b', [])
    seedFolders([
      { name: 'a', count: 1 },
      { name: 'b', count: 0 },
    ])

    // Hold the POST so we can inspect the optimistic state.
    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useRenameNote(), { wrapper })
    act(() => {
      result.current.mutate({ old_path: 'a/x.md', new_path: 'b/x.md' })
    })

    await waitFor(() => {
      const oldList = qc.getQueryData<{ notes: Array<{ path: string }> }>([
        'folderNotes',
        '42',
        'a',
      ])
      expect(oldList?.notes.map((n) => n.path)).toEqual([])
    })

    const newList = qc.getQueryData<{ notes: Array<{ path: string }> }>([
      'folderNotes',
      '42',
      'b',
    ])
    expect(newList?.notes.map((n) => n.path)).toContain('b/x.md')

    const folders = qc.getQueryData<{ folders: Array<{ name: string; count: number }> }>([
      'folders',
      '42',
    ])
    expect(folders?.folders.find((f) => f.name === 'a')?.count).toBe(0)
    expect(folders?.folders.find((f) => f.name === 'b')?.count).toBe(1)

    // Settle the promise so React Query unwinds cleanly.
    resolvePost({ renamed: true, old_path: 'a/x.md', new_path: 'b/x.md' })
  })

  it('restores the pre-mutation cache snapshot when the mutation rejects', async () => {
    seedFolderNotes('a', [{ path: 'a/x.md', title: 'X' }])
    seedFolderNotes('b', [])
    seedFolders([
      { name: 'a', count: 1 },
      { name: 'b', count: 0 },
    ])

    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useRenameNote(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ old_path: 'a/x.md', new_path: 'b/x.md' })
      } catch {
        // Expected — we want the rollback.
      }
    })

    const oldList = qc.getQueryData<{ notes: Array<{ path: string }> }>([
      'folderNotes',
      '42',
      'a',
    ])
    expect(oldList?.notes.map((n) => n.path)).toEqual(['a/x.md'])

    const newList = qc.getQueryData<{ notes: Array<{ path: string }> }>([
      'folderNotes',
      '42',
      'b',
    ])
    expect(newList?.notes.map((n) => n.path)).toEqual([])

    const folders = qc.getQueryData<{ folders: Array<{ name: string; count: number }> }>([
      'folders',
      '42',
    ])
    expect(folders?.folders.find((f) => f.name === 'a')?.count).toBe(1)
    expect(folders?.folders.find((f) => f.name === 'b')?.count).toBe(0)
  })
})

describe('optimistic delete note', () => {
  it('removes the note from the folder cache before the request resolves', async () => {
    seedFolderNotes('', [
      { id: '1', path: 'gone.md', title: 'Gone' },
      { id: '2', path: 'stays.md', title: 'Stays' },
    ])
    seedFolders([{ name: '', count: 2 }])

    let resolveDel!: (v: unknown) => void
    del.mockReturnValue(new Promise((r) => (resolveDel = r)))

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    act(() => {
      result.current.mutate({ id: '1', path: 'gone.md' })
    })

    await waitFor(() => {
      const list = qc.getQueryData<{ notes: Array<{ path: string }> }>([
        'folderNotes',
        '42',
        '',
      ])
      expect(list?.notes.map((n) => n.path)).toEqual(['stays.md'])
    })

    resolveDel({ deleted: true })
  })

  it('restores the cache when the delete fails', async () => {
    seedFolderNotes('', [
      { id: '1', path: 'gone.md', title: 'Gone' },
      { id: '2', path: 'stays.md', title: 'Stays' },
    ])
    seedFolders([{ name: '', count: 2 }])

    del.mockRejectedValue(new ApiError(500, 'boom'))

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ id: '1', path: 'gone.md' })
      } catch {
        // expected
      }
    })

    const list = qc.getQueryData<{ notes: Array<{ path: string }> }>([
      'folderNotes',
      '42',
      '',
    ])
    expect(list?.notes.map((n) => n.path).sort()).toEqual(['gone.md', 'stays.md'])
  })
})

// ── Id-stable optimistic updates (URL-by-id Task 9) ─────────
//
// Notes are cached by id (`['note', vaultId, id]`). On rename, the
// id never changes — only `path` / `folder` shift. The cache entry
// must update in place under the same key; the prior path-keyed
// shuffle (write to new key + remove old) is dead.

function seedNoteById(id: string, note: Partial<Note>) {
  qc.setQueryData(['note', '42', id], {
    id,
    path: '',
    title: '',
    folder: '',
    tags: [],
    version: 1,
    content: '',
    mtime: 's',
    created_at: 's',
    updated_at: 's',
    ...note,
  } satisfies Note)
}

describe('optimistic rename note — id-stable cache', () => {
  it('updates the note body cache in place under [note, vaultId, id]', async () => {
    seedFolderNotes('a', [{ id: '42', path: 'a/x.md', title: 'X' }])
    seedFolderNotes('b', [])
    seedFolders([
      { name: 'a', count: 1 },
      { name: 'b', count: 0 },
    ])
    seedNoteById('42', { id: '42', path: 'a/x.md', folder: 'a', title: 'X', content: '# X' })

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useRenameNote(), { wrapper })
    act(() => {
      result.current.mutate({ old_path: 'a/x.md', new_path: 'b/y.md' })
    })

    await waitFor(() => {
      // Same key — id 42 — value updated in place.
      const cached = qc.getQueryData<Note>(['note', '42', '42'])
      expect(cached?.path).toBe('b/y.md')
      expect(cached?.folder).toBe('b')
      // Content + title preserved.
      expect(cached?.content).toBe('# X')
      expect(cached?.title).toBe('X')
    })

    // The old path key was never used; it must not appear.
    expect(qc.getQueryData(['note', '42', 'a/x.md'])).toBeUndefined()
    expect(qc.getQueryData(['note', '42', 'b/y.md'])).toBeUndefined()

    resolvePost({
      renamed: true,
      old_path: 'a/x.md',
      new_path: 'b/y.md',
      note: { id: '42', path: 'b/y.md' },
    })
  })

  it('restores the note body cache under [note, vaultId, id] on rollback', async () => {
    seedFolderNotes('a', [{ id: '42', path: 'a/x.md', title: 'X' }])
    seedFolderNotes('b', [])
    seedNoteById('42', { id: '42', path: 'a/x.md', folder: 'a', content: '# X' })

    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useRenameNote(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ old_path: 'a/x.md', new_path: 'b/y.md' })
      } catch {
        // expected
      }
    })

    const cached = qc.getQueryData<Note>(['note', '42', '42'])
    expect(cached?.path).toBe('a/x.md')
    expect(cached?.folder).toBe('a')
  })
})

describe('optimistic rename folder — rewrites cached notes under old prefix', () => {
  it('rewrites path + folder on every cached [note, vaultId, *] under the old prefix', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [
        { name: 'src', count: 2 },
        { name: 'src/sub', count: 1 },
      ],
    })
    seedNoteById('10', { id: '10', path: 'src/a.md', folder: 'src' })
    seedNoteById('11', { id: '11', path: 'src/sub/b.md', folder: 'src/sub' })
    // An unrelated note — must NOT be touched.
    seedNoteById('99', { id: '99', path: 'other/c.md', folder: 'other' })

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useRenameFolder(), { wrapper })
    act(() => {
      result.current.mutate({ old_path: 'src', new_path: 'dst' })
    })

    await waitFor(() => {
      expect(qc.getQueryData<Note>(['note', '42', '10'])?.path).toBe('dst/a.md')
    })
    expect(qc.getQueryData<Note>(['note', '42', '10'])?.folder).toBe('dst')
    expect(qc.getQueryData<Note>(['note', '42', '11'])?.path).toBe('dst/sub/b.md')
    expect(qc.getQueryData<Note>(['note', '42', '11'])?.folder).toBe('dst/sub')
    // Untouched.
    expect(qc.getQueryData<Note>(['note', '42', '99'])?.path).toBe('other/c.md')

    resolvePost({ renamed: true, old_path: 'src', new_path: 'dst', count: 2 })
  })

  it('restores cached [note, vaultId, *] entries when the folder rename rejects', async () => {
    seedNoteById('10', { id: '10', path: 'src/a.md', folder: 'src' })
    seedNoteById('11', { id: '11', path: 'src/sub/b.md', folder: 'src/sub' })

    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useRenameFolder(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ old_path: 'src', new_path: 'dst' })
      } catch {
        // expected
      }
    })

    expect(qc.getQueryData<Note>(['note', '42', '10'])?.path).toBe('src/a.md')
    expect(qc.getQueryData<Note>(['note', '42', '10'])?.folder).toBe('src')
    expect(qc.getQueryData<Note>(['note', '42', '11'])?.path).toBe('src/sub/b.md')
    expect(qc.getQueryData<Note>(['note', '42', '11'])?.folder).toBe('src/sub')
  })
})

// ── useFolders surfaces id + parent_id (Headless Tree Task 17) ────
//
// Backend `GET /api/folders` returns `{folders: [{id, name, count,
// parent_id}, ...]}` (commit 935b7bbf). The headless-tree consumer
// keys nodes by id and discovers tree shape via parent_id, so the
// Folder type and the parsed query data must surface both fields
// verbatim. `name` continues to carry the FULL folder path — that
// shape is load-bearing for existing consumers and stays.

describe('useFolderNotesById', () => {
  it('fetches notes for the given folder id', async () => {
    get.mockResolvedValue({
      notes: [
        {
          id: '100',
          path: 'foo/a.md',
          title: 'A',
          folder: 'foo',
          tags: [],
          version: 1,
          mtime: 's',
          created_at: 's',
          updated_at: 's',
        },
      ],
    })

    const { result } = renderHook(() => useFolderNotesById('42'), { wrapper })
    await waitFor(() => expect(result.current.data).toBeDefined())

    expect(get).toHaveBeenCalledWith('/folders/by-id/42/notes')
    expect(result.current.data?.[0]).toMatchObject({
      id: expect.any(String),
      path: expect.any(String),
    })
  })

  it('disabled when folderId is null', () => {
    const { result } = renderHook(() => useFolderNotesById(null), { wrapper })
    expect(result.current.fetchStatus).toBe('idle')
    expect(get).not.toHaveBeenCalled()
  })
})

describe('Folder type', () => {
  it('exposes id (string), parent_id (string | null), name (string), count (number)', () => {
    expectTypeOf<Folder>().toMatchTypeOf<{
      id: string
      parent_id: string | null
      name: string
      count: number
    }>()
  })
})

describe('useFolders', () => {
  it('passes through id + parent_id from the backend response', async () => {
    get.mockResolvedValue({
      folders: [
        { id: '7', parent_id: null, name: 'top', count: 2 },
        { id: '8', parent_id: '7', name: 'top/sub', count: 1 },
      ],
    })

    const { result } = renderHook(() => useFolders(), { wrapper })
    await waitFor(() => expect(result.current.data).toBeDefined())

    expect(get).toHaveBeenCalledWith('/folders')
    const folders = result.current.data ?? []
    expect(folders).toHaveLength(2)
    expect(folders[0]).toMatchObject({
      id: '7',
      parent_id: null,
      name: 'top',
      count: 2,
    })
    expect(folders[1]).toMatchObject({
      id: '8',
      parent_id: '7',
      name: 'top/sub',
      count: 1,
    })
  })
})

// ── Batch mutation hooks (Task 19) ────────────────────────────
//
// Four hooks mirroring the single-target rename/delete pattern but
// targeting the backend's atomic /batch-{delete,move} endpoints. Each:
//   1. Sends a UUID `X-Idempotency-Key` header (backend dedupes via the
//      IdempotencyKey plug installed Tasks 7/8).
//   2. Patches every affected cache slice in `onMutate` so the UI moves
//      instantly — important for tree multi-select where the user just
//      ctrl-clicked five rows and hit delete.
//   3. Rolls those patches back on error.
//   4. Invalidates `['folders']` + `['folder-notes-by-id']` on success
//      so the server is the eventual source of truth (and so any
//      server-side cascade we don't model client-side gets reconciled).

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function seedFolderNotesById(
  folderId: string,
  notes: Array<{ id: string; path?: string; folder?: string }>,
) {
  qc.setQueryData(
    ['folder-notes-by-id', '42', folderId],
    notes.map((n) => ({
      id: n.id,
      path: n.path ?? `f${folderId}/n${n.id}.md`,
      title: `n${n.id}`,
      folder: n.folder ?? `f${folderId}`,
      tags: [],
      version: 1,
      mtime: '',
      created_at: '',
      updated_at: '',
    })),
  )
}

describe('useBatchDeleteNotes', () => {
  it('POSTs ids and sends a UUID X-Idempotency-Key header', async () => {
    post.mockResolvedValue({ deleted: 2 })

    const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ ids: ['1', '2'] })
    })

    expect(post).toHaveBeenCalledWith(
      '/notes/batch-delete',
      { ids: ['1', '2'] },
      expect.objectContaining({
        headers: expect.objectContaining({
          'X-Idempotency-Key': expect.stringMatching(UUID_RE),
        }),
      }),
    )
  })

  it('optimistically removes ids from every cached folder-notes-by-id list', async () => {
    seedFolderNotesById('5', [{ id: '1' }, { id: '2' }, { id: '3' }])
    seedFolderNotesById('6', [{ id: '4' }])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper })
    act(() => {
      result.current.mutate({ ids: ['1', '2', '4'] })
    })

    await waitFor(() => {
      const list5 = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', '5'])
      expect(list5?.map((n) => n.id)).toEqual(['3'])
    })

    const list6 = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', '6'])
    expect(list6?.map((n) => n.id)).toEqual([])

    resolvePost({ deleted: 3 })
  })

  it('rolls back every patched list when the server rejects', async () => {
    seedFolderNotesById('5', [{ id: '1' }, { id: '2' }, { id: '3' }])
    post.mockRejectedValue(new ApiError(500, 'boom'))

    const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ ids: ['1', '2'] })
      } catch {
        // expected
      }
    })

    const list = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', '5'])
    expect(list?.map((n) => n.id).sort()).toEqual(['1', '2', '3'])
  })

  it('invalidates folders + folder-notes-by-id on success', async () => {
    post.mockResolvedValue({ deleted: 2 })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ ids: ['1', '2'] })
    })

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folder-notes-by-id', '42'] })
  })

  it('optimistically strips deleted root notes from the by-id root list', async () => {
    // Root notes share the one id-keyed cache under the 'root' sentinel.
    seedFolderNotesById('root', [{ id: '1', path: 'a.md', folder: '' }, { id: '2', path: 'b.md', folder: '' }])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper })
    act(() => {
      result.current.mutate({ ids: ['1'] })
    })

    await waitFor(() => {
      const root = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', 'root'])
      expect(root?.map((n) => n.id)).toEqual(['2'])
    })

    resolvePost({ deleted: 1 })
  })

  it('rolls back the by-id root list when the server rejects', async () => {
    seedFolderNotesById('root', [{ id: '1', path: 'a.md', folder: '' }])
    post.mockRejectedValue(new ApiError(500, 'boom'))

    const { result } = renderHook(() => useBatchDeleteNotes(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ ids: ['1'] })
      } catch {
        // expected
      }
    })

    const root = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', 'root'])
    expect(root?.map((n) => n.id)).toEqual(['1'])
  })
})

describe('useCreateNote — optimistic placeholder', () => {
  it('inserts a placeholder at root (by-id "root") then swaps it for the real note', async () => {
    // Root notes share the one id-keyed cache under the 'root' sentinel.
    qc.setQueryData(['folder-notes-by-id', '42', 'root'], [])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useCreateNote(), { wrapper })
    act(() => {
      result.current.mutate({ folder: '' })
    })

    await waitFor(() => {
      const root = qc.getQueryData<Array<{ id: string; title: string }>>([
        'folder-notes-by-id',
        '42',
        'root',
      ])
      expect(root).toHaveLength(1)
      expect(root?.[0]?.id).toMatch(/^optimistic-/)
      expect(root?.[0]?.title).toBe('Untitled')
    })

    resolvePost({ note: { id: 'real-1' } })

    await waitFor(() => {
      const root = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', 'root'])
      expect(root?.[0]?.id).toBe('real-1')
    })
  })

  it('inserts a placeholder into the by-id list for a subfolder', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [{ id: 'f9', parent_id: null, name: 'sub', count: 0 }],
    })
    qc.setQueryData(['folder-notes-by-id', '42', 'f9'], [])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useCreateNote(), { wrapper })
    act(() => {
      result.current.mutate({ folder: 'sub' })
    })

    await waitFor(() => {
      const byId = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', 'f9'])
      expect(byId).toHaveLength(1)
      expect(byId?.[0]?.id).toMatch(/^optimistic-/)
    })

    resolvePost({ note: { id: 'real-2' } })

    await waitFor(() => {
      const byId = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', 'f9'])
      expect(byId?.[0]?.id).toBe('real-2')
    })
  })
})

describe('useBatchMoveNotes', () => {
  it('POSTs ids + target_folder_id with UUID idempotency header', async () => {
    post.mockResolvedValue({ moved: 2 })

    const { result } = renderHook(() => useBatchMoveNotes(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ ids: ['1', '2'], target_folder_id: '9' })
    })

    expect(post).toHaveBeenCalledWith(
      '/notes/batch-move',
      { ids: ['1', '2'], target_folder_id: '9' },
      expect.objectContaining({
        headers: expect.objectContaining({
          'X-Idempotency-Key': expect.stringMatching(UUID_RE),
        }),
      }),
    )
  })

  it('optimistically strips moved notes from source lists before resolution', async () => {
    seedFolderNotesById('5', [{ id: '1' }, { id: '2' }, { id: '3' }])
    seedFolderNotesById('9', [{ id: '4' }])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useBatchMoveNotes(), { wrapper })
    act(() => {
      result.current.mutate({ ids: ['1', '2'], target_folder_id: '9' })
    })

    await waitFor(() => {
      const src = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', '5'])
      expect(src?.map((n) => n.id)).toEqual(['3'])
    })

    resolvePost({ moved: 2 })
  })

  it('rolls back source list on server error (e.g. 409)', async () => {
    seedFolderNotesById('5', [{ id: '1' }, { id: '2' }, { id: '3' }])
    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useBatchMoveNotes(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ ids: ['1', '2'], target_folder_id: '9' })
      } catch {
        // expected
      }
    })

    const src = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', '5'])
    expect(src?.map((n) => n.id).sort()).toEqual(['1', '2', '3'])
  })

  it('optimistically updates folder counts so the tree rebuilds on a move', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [
        { id: '5', parent_id: null, name: 'src', count: 3 },
        { id: '9', parent_id: null, name: 'dst', count: 1 },
      ],
    })
    seedFolderNotesById('5', [{ id: '1' }, { id: '2' }, { id: '3' }])
    seedFolderNotesById('9', [{ id: '4' }])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useBatchMoveNotes(), { wrapper })
    act(() => {
      result.current.mutate({ ids: ['1', '2'], target_folder_id: '9' })
    })

    await waitFor(() => {
      const folders = qc.getQueryData<{ folders: Folder[] }>(['folders', '42'])
      const byId = Object.fromEntries((folders?.folders ?? []).map((f) => [f.id, f.count]))
      expect(byId['5']).toBe(1) // 3 source notes - 2 moved
      expect(byId['9']).toBe(3) // 1 target note + 2 moved
    })

    resolvePost({ moved: 2 })
  })

  it('rolls back folder counts on server error', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [
        { id: '5', parent_id: null, name: 'src', count: 3 },
        { id: '9', parent_id: null, name: 'dst', count: 1 },
      ],
    })
    seedFolderNotesById('5', [{ id: '1' }, { id: '2' }, { id: '3' }])
    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useBatchMoveNotes(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ ids: ['1', '2'], target_folder_id: '9' })
      } catch {
        // expected
      }
    })

    const folders = qc.getQueryData<{ folders: Folder[] }>(['folders', '42'])
    const byId = Object.fromEntries((folders?.folders ?? []).map((f) => [f.id, f.count]))
    expect(byId['5']).toBe(3)
    expect(byId['9']).toBe(1)
  })

  it('moves notes to the vault root: appends to the by-id root list, strips the source', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [{ id: '5', parent_id: null, name: 'src', count: 2 }],
    })
    seedFolderNotesById('5', [{ id: '1' }, { id: '2' }])
    // Root shares the one id-keyed cache under the 'root' sentinel.
    qc.setQueryData(['folder-notes-by-id', '42', 'root'], [])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useBatchMoveNotes(), { wrapper })
    act(() => {
      result.current.mutate({ ids: ['1'], target_folder_id: 'root' })
    })

    await waitFor(() => {
      const root = qc.getQueryData<Array<{ id: string; folder: string }>>([
        'folder-notes-by-id',
        '42',
        'root',
      ])
      expect(root?.map((n) => n.id)).toContain('1')
      expect(root?.find((n) => n.id === '1')?.folder).toBe('')
      const src = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', '5'])
      expect(src?.map((n) => n.id)).toEqual(['2'])
    })

    resolvePost({ moved: 1 })
  })

  it('moves a note FROM the root into a folder (strips the by-id root list)', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [{ id: '9', parent_id: null, name: 'dst', count: 0 }],
    })
    qc.setQueryData(['folder-notes-by-id', '42', '9'], [])
    seedFolderNotesById('root', [{ id: '1', path: 'a.md', folder: '' }])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useBatchMoveNotes(), { wrapper })
    act(() => {
      result.current.mutate({ ids: ['1'], target_folder_id: '9' })
    })

    await waitFor(() => {
      const root = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', 'root'])
      expect(root?.map((n) => n.id)).toEqual([])
      const dst = qc.getQueryData<Array<{ id: string }>>(['folder-notes-by-id', '42', '9'])
      expect(dst?.map((n) => n.id)).toContain('1')
    })

    resolvePost({ moved: 1 })
  })
})

describe('useBatchDeleteFolders', () => {
  it('POSTs ids with UUID idempotency header', async () => {
    post.mockResolvedValue({ deleted: 2 })

    const { result } = renderHook(() => useBatchDeleteFolders(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ ids: ['7', '8'] })
    })

    expect(post).toHaveBeenCalledWith(
      '/folders/batch-delete',
      { ids: ['7', '8'] },
      expect.objectContaining({
        headers: expect.objectContaining({
          'X-Idempotency-Key': expect.stringMatching(UUID_RE),
        }),
      }),
    )
  })

  it('optimistically removes target folders + descendants from the folders cache', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [
        { id: '7', parent_id: null, name: 'top', count: 0 },
        { id: '8', parent_id: '7', name: 'top/sub', count: 0 },
        { id: '9', parent_id: null, name: 'other', count: 0 },
      ],
    })
    seedFolderNotesById('7', [{ id: '1' }])
    seedFolderNotesById('8', [{ id: '2' }])

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useBatchDeleteFolders(), { wrapper })
    act(() => {
      result.current.mutate({ ids: ['7'] })
    })

    await waitFor(() => {
      const folders = qc.getQueryData<{ folders: Folder[] }>(['folders', '42'])
      expect(folders?.folders.map((f) => f.id).sort()).toEqual(['9'])
    })

    // by-id lists for removed folder + descendant are dropped, sibling intact
    expect(qc.getQueryData(['folder-notes-by-id', '42', '7'])).toBeUndefined()
    expect(qc.getQueryData(['folder-notes-by-id', '42', '8'])).toBeUndefined()

    resolvePost({ deleted: 2 })
  })

  it('rolls back the folders cache when the server rejects', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [
        { id: '7', parent_id: null, name: 'top', count: 0 },
        { id: '9', parent_id: null, name: 'other', count: 0 },
      ],
    })
    post.mockRejectedValue(new ApiError(500, 'boom'))

    const { result } = renderHook(() => useBatchDeleteFolders(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ ids: ['7'] })
      } catch {
        // expected
      }
    })

    const folders = qc.getQueryData<{ folders: Folder[] }>(['folders', '42'])
    expect(folders?.folders.map((f) => f.id).sort()).toEqual(['7', '9'])
  })
})

describe('useBatchMoveFolders', () => {
  it('POSTs target_parent_id (NOT target_folder_id) with UUID idempotency header', async () => {
    post.mockResolvedValue({ moved: 1 })

    const { result } = renderHook(() => useBatchMoveFolders(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ ids: ['7'], target_parent_id: '9' })
    })

    expect(post).toHaveBeenCalledWith(
      '/folders/batch-move',
      // Regression: the folders endpoint uses `target_parent_id`, NOT
      // `target_folder_id` (notes endpoint). Don't conflate them.
      { ids: ['7'], target_parent_id: '9' },
      expect.objectContaining({
        headers: expect.objectContaining({
          'X-Idempotency-Key': expect.stringMatching(UUID_RE),
        }),
      }),
    )
  })

  it('optimistically rewrites parent_id + name prefix for moved folder + descendants', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [
        { id: '7', parent_id: null, name: 'src', count: 0 },
        { id: '8', parent_id: '7', name: 'src/sub', count: 0 },
        { id: '9', parent_id: null, name: 'dst', count: 0 },
      ],
    })

    let resolvePost!: (v: unknown) => void
    post.mockReturnValue(new Promise((r) => (resolvePost = r)))

    const { result } = renderHook(() => useBatchMoveFolders(), { wrapper })
    act(() => {
      result.current.mutate({ ids: ['7'], target_parent_id: '9' })
    })

    await waitFor(() => {
      const folders = qc.getQueryData<{ folders: Folder[] }>(['folders', '42'])
      expect(folders?.folders.find((f) => f.id === '7')?.name).toBe('dst/src')
    })

    const folders = qc.getQueryData<{ folders: Folder[] }>(['folders', '42'])
    // Moved folder's parent flips to the target.
    expect(folders?.folders.find((f) => f.id === '7')?.parent_id).toBe('9')
    // Descendant's path prefix is rewritten; parent_id is unchanged
    // (still points at id 7).
    expect(folders?.folders.find((f) => f.id === '8')?.name).toBe('dst/src/sub')
    expect(folders?.folders.find((f) => f.id === '8')?.parent_id).toBe('7')
    // Unrelated folder untouched.
    expect(folders?.folders.find((f) => f.id === '9')?.name).toBe('dst')

    resolvePost({ moved: 2 })
  })

  it('rolls back on error', async () => {
    qc.setQueryData(['folders', '42'], {
      folders: [
        { id: '7', parent_id: null, name: 'src', count: 0 },
        { id: '8', parent_id: '7', name: 'src/sub', count: 0 },
      ],
    })
    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useBatchMoveFolders(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ ids: ['7'], target_parent_id: '9' })
      } catch {
        // expected
      }
    })

    const folders = qc.getQueryData<{ folders: Folder[] }>(['folders', '42'])
    expect(folders?.folders.find((f) => f.id === '7')?.name).toBe('src')
    expect(folders?.folders.find((f) => f.id === '7')?.parent_id).toBeNull()
    expect(folders?.folders.find((f) => f.id === '8')?.name).toBe('src/sub')
  })
})

describe('useSearch', () => {
  it('forwards an abort signal so superseded searches are cancelled', async () => {
    post.mockResolvedValue({ results: [] })

    const { result } = renderHook(() => useSearch('alpha'), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(post).toHaveBeenCalledWith(
      '/search',
      { query: 'alpha', limit: 20 },
      { signal: expect.any(AbortSignal) },
    )
  })

  it('keeps previous results visible while the next query is in flight', async () => {
    const firstResults = [{ id: '1', path: 'a.md', title: 'A' }]
    post.mockResolvedValueOnce({ results: firstResults })

    const { result, rerender } = renderHook(({ q }) => useSearch(q), {
      wrapper,
      initialProps: { q: 'alpha' },
    })
    await waitFor(() => expect(result.current.data).toEqual(firstResults))

    // Second query never resolves during the assertion window — previous
    // results must remain rendered instead of flickering to empty.
    post.mockImplementationOnce(() => new Promise(() => {}))
    rerender({ q: 'alpha beta' })

    expect(result.current.data).toEqual(firstResults)
    expect(result.current.isPlaceholderData).toBe(true)
  })
})

describe('useAttachments', () => {
  it('fetches /attachments and returns the attachments array', async () => {
    get.mockResolvedValue({
      attachments: [
        { id: 'a-1', path: 'a.png', mime_type: 'image/png', size_bytes: 10, mtime: 1, updated_at: '2026-06-10T00:00:00Z' },
      ],
    })

    const { result } = renderHook(() => useAttachments(), { wrapper })
    await waitFor(() => expect(result.current.data).toBeDefined())

    expect(get).toHaveBeenCalledWith('/attachments')
    expect(result.current.data?.[0]?.path).toBe('a.png')
  })
})

describe('useRenameAttachment', () => {
  it('POSTs /attachments/rename with {old_path, new_path} and invalidates folders + attachments', async () => {
    post.mockResolvedValue({ renamed: true, old_path: 'img/a.png', new_path: 'img/b.png' })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useRenameAttachment(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ old_path: 'img/a.png', new_path: 'img/b.png' })
    })

    expect(post).toHaveBeenCalledWith('/attachments/rename', {
      old_path: 'img/a.png',
      new_path: 'img/b.png',
    })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['attachments', '42'] })
  })

  it('surfaces 409 as ApiError', async () => {
    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useRenameAttachment(), { wrapper })
    await expect(
      result.current.mutateAsync({ old_path: 'a.png', new_path: 'b.png' }),
    ).rejects.toMatchObject({ status: 409 })
  })
})

describe('useBatchMoveAttachments', () => {
  it('POSTs paths + target_folder with UUID X-Idempotency-Key header', async () => {
    post.mockResolvedValue({ moved: 2 })

    const { result } = renderHook(() => useBatchMoveAttachments(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ paths: ['a.png', 'b.png'], target_folder: 'img' })
    })

    expect(post).toHaveBeenCalledWith(
      '/attachments/batch-move',
      { paths: ['a.png', 'b.png'], target_folder: 'img' },
      expect.objectContaining({
        headers: expect.objectContaining({
          'X-Idempotency-Key': expect.stringMatching(UUID_RE),
        }),
      }),
    )
  })

  it('invalidates folders + attachments on success', async () => {
    post.mockResolvedValue({ moved: 1 })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useBatchMoveAttachments(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ paths: ['a.png'], target_folder: 'img' })
    })

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['attachments', '42'] })
  })
})

describe('useBatchDeleteAttachments', () => {
  it('POSTs paths with UUID X-Idempotency-Key header', async () => {
    post.mockResolvedValue({ deleted: 2 })

    const { result } = renderHook(() => useBatchDeleteAttachments(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ paths: ['a.png', 'b.png'] })
    })

    expect(post).toHaveBeenCalledWith(
      '/attachments/batch-delete',
      { paths: ['a.png', 'b.png'] },
      expect.objectContaining({
        headers: expect.objectContaining({
          'X-Idempotency-Key': expect.stringMatching(UUID_RE),
        }),
      }),
    )
  })

  it('invalidates folders + attachments on success', async () => {
    post.mockResolvedValue({ deleted: 2 })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useBatchDeleteAttachments(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ paths: ['a.png', 'b.png'] })
    })

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', '42'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['attachments', '42'] })
  })
})

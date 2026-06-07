import React from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

vi.mock('sonner', () => ({
  toast: {
    error: vi.fn(),
    success: vi.fn(),
    info: vi.fn(),
  },
}))

// Pin the active vault id so cache keys are deterministic for the
// optimistic-update tests below. The hook reads from a module-scoped
// store + localStorage; setting localStorage before module import is
// brittle, so we mock the hook directly.
vi.mock('./active-vault', async () => {
  const actual = await vi.importActual<typeof import('./active-vault')>('./active-vault')
  return { ...actual, useActiveVaultId: () => 42 }
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
  useAcceptTerms,
  useCancelSubscription,
  useConfirmPlanChange,
  useDeleteFolder,
  useDeleteNote,
  useDuplicateNote,
  usePlanChangePreview,
  useRenameFolder,
  useRenameNote,
  useReverseCancel,
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
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', 42] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', 42] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['note', 42] })
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
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', 42] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', 42] })
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
  it('DELETEs encoded path and invalidates folders + folder list + removes note', async () => {
    del.mockResolvedValue({ deleted: true })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')
    const removeSpy = vi.spyOn(qc, 'removeQueries')

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ path: 'foo bar/x y.md' })
    })

    // Each path segment is URL-encoded but slashes are preserved so the
    // Phoenix splat route matches.
    expect(del).toHaveBeenCalledWith('/notes/foo%20bar/x%20y.md')
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', 42] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', 42] })
    // The optimistic onMutate removes the note's body cache, so we
    // assert removeQueries was called with the specific keyed note.
    expect(removeSpy).toHaveBeenCalledWith({ queryKey: ['note', 42, 'foo bar/x y.md'] })
  })

  it('surfaces backend errors as ApiError', async () => {
    del.mockRejectedValue(new ApiError(404, 'not found'))

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    await expect(result.current.mutateAsync({ path: 'gone.md' })).rejects.toMatchObject({
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
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', 42] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', 42] })
  })

  it('surfaces 409 from POST as ApiError so callers can toast', async () => {
    get.mockResolvedValue({ content: 'x' })
    post.mockRejectedValue(new ApiError(409, 'conflict'))

    const { result } = renderHook(() => useDuplicateNote(), { wrapper })
    await expect(
      result.current.mutateAsync({ src_path: 'a.md', new_path: 'a (copy).md' }),
    ).rejects.toMatchObject({ status: 409 })
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
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders', 42] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes', 42] })
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

function seedFolderNotes(folder: string, notes: Array<Partial<{ path: string; title: string }>>) {
  qc.setQueryData(['folderNotes', 42, folder], {
    notes: notes.map((n) => ({
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
  qc.setQueryData(['folders', 42], { folders })
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
        42,
        'a',
      ])
      expect(oldList?.notes.map((n) => n.path)).toEqual([])
    })

    const newList = qc.getQueryData<{ notes: Array<{ path: string }> }>([
      'folderNotes',
      42,
      'b',
    ])
    expect(newList?.notes.map((n) => n.path)).toContain('b/x.md')

    const folders = qc.getQueryData<{ folders: Array<{ name: string; count: number }> }>([
      'folders',
      42,
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
      42,
      'a',
    ])
    expect(oldList?.notes.map((n) => n.path)).toEqual(['a/x.md'])

    const newList = qc.getQueryData<{ notes: Array<{ path: string }> }>([
      'folderNotes',
      42,
      'b',
    ])
    expect(newList?.notes.map((n) => n.path)).toEqual([])

    const folders = qc.getQueryData<{ folders: Array<{ name: string; count: number }> }>([
      'folders',
      42,
    ])
    expect(folders?.folders.find((f) => f.name === 'a')?.count).toBe(1)
    expect(folders?.folders.find((f) => f.name === 'b')?.count).toBe(0)
  })
})

describe('optimistic delete note', () => {
  it('removes the note from the folder cache before the request resolves', async () => {
    seedFolderNotes('', [
      { path: 'gone.md', title: 'Gone' },
      { path: 'stays.md', title: 'Stays' },
    ])
    seedFolders([{ name: '', count: 2 }])

    let resolveDel!: (v: unknown) => void
    del.mockReturnValue(new Promise((r) => (resolveDel = r)))

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    act(() => {
      result.current.mutate({ path: 'gone.md' })
    })

    await waitFor(() => {
      const list = qc.getQueryData<{ notes: Array<{ path: string }> }>([
        'folderNotes',
        42,
        '',
      ])
      expect(list?.notes.map((n) => n.path)).toEqual(['stays.md'])
    })

    resolveDel({ deleted: true })
  })

  it('restores the cache when the delete fails', async () => {
    seedFolderNotes('', [
      { path: 'gone.md', title: 'Gone' },
      { path: 'stays.md', title: 'Stays' },
    ])
    seedFolders([{ name: '', count: 2 }])

    del.mockRejectedValue(new ApiError(500, 'boom'))

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    await act(async () => {
      try {
        await result.current.mutateAsync({ path: 'gone.md' })
      } catch {
        // expected
      }
    })

    const list = qc.getQueryData<{ notes: Array<{ path: string }> }>([
      'folderNotes',
      42,
      '',
    ])
    expect(list?.notes.map((n) => n.path).sort()).toEqual(['gone.md', 'stays.md'])
  })
})

import React from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { post, del } = vi.hoisted(() => ({ post: vi.fn(), del: vi.fn() }))
vi.mock('./client', async () => {
  const actual = await vi.importActual<typeof import('./client')>('./client')
  return {
    ...actual,
    api: { get: vi.fn(), post, patch: vi.fn(), del },
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
  usePlanChangePreview,
  useRenameFolder,
  useRenameNote,
  useReverseCancel,
} from './queries'

let qc: QueryClient

beforeEach(() => {
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
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['note'] })
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
    post.mockResolvedValue({ renamed: true, old_path: 'a', new_path: 'b' })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')

    const { result } = renderHook(() => useRenameFolder(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ old_path: 'a', new_path: 'b' })
    })

    expect(post).toHaveBeenCalledWith('/folders/rename', {
      old_path: 'a',
      new_path: 'b',
    })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes'] })
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
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes'] })
    expect(removeSpy).toHaveBeenCalledWith({ queryKey: ['note'] })
  })

  it('surfaces backend errors as ApiError', async () => {
    del.mockRejectedValue(new ApiError(404, 'not found'))

    const { result } = renderHook(() => useDeleteNote(), { wrapper })
    await expect(result.current.mutateAsync({ path: 'gone.md' })).rejects.toMatchObject({
      status: 404,
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
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folders'] })
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ['folderNotes'] })
  })

  it('surfaces backend errors as ApiError', async () => {
    del.mockRejectedValue(new ApiError(404, 'not found'))

    const { result } = renderHook(() => useDeleteFolder(), { wrapper })
    await expect(result.current.mutateAsync({ path: 'gone' })).rejects.toMatchObject({
      status: 404,
    })
  })
})

import React from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { post } = vi.hoisted(() => ({ post: vi.fn() }))
vi.mock('./client', () => ({
  api: { get: vi.fn(), post, patch: vi.fn(), del: vi.fn() },
  setTokenGetter: vi.fn(),
}))

import { useAcceptTerms } from './queries'

let qc: QueryClient

beforeEach(() => {
  post.mockReset()
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

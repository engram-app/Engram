import { describe, it, expect, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient } from '@tanstack/react-query'
import { useEngramTree } from './use-engram-tree'
import type { Folder, NoteSummary } from '../../api/queries'

describe('useEngramTree', () => {
  const folders: Folder[] = [{ id: '1', parent_id: null, name: 'Projects', count: 1 }]
  const rootNotes: NoteSummary[] = []
  const scrollRef = { current: null as HTMLDivElement | null }
  const baseDeps = {
    folders,
    rootNotes,
    qc: new QueryClient(),
    vaultId: 'v',
    sort: 'name-asc' as const,
    scrollParentRef: scrollRef,
    onRenameCommit: vi.fn(),
    onMove: vi.fn(),
  }

  it('returns a tree object + virtualizer', () => {
    const { result } = renderHook(() => useEngramTree(baseDeps))
    expect(result.current.tree).toBeDefined()
    expect(result.current.virtualizer).toBeDefined()
    expect(Array.isArray(result.current.items)).toBe(true)
  })
})

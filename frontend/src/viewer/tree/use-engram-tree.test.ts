import { describe, it, expect, vi } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient } from '@tanstack/react-query'
import { useEngramTree, treeStructureKey } from './use-engram-tree'
import type { Folder, NoteSummary } from '../../api/queries'

describe('treeStructureKey', () => {
  it('changes when a folder count changes (so a move rebuilds the tree)', () => {
    const before = treeStructureKey([{ id: 'f1', count: 0 }], [], 'name-asc')
    const after = treeStructureKey([{ id: 'f1', count: 1 }], [], 'name-asc')
    expect(after).not.toBe(before)
  })

  it('changes when root notes change', () => {
    const before = treeStructureKey([{ id: 'f1', count: 0 }], [], 'name-asc')
    const after = treeStructureKey([{ id: 'f1', count: 0 }], ['n1'], 'name-asc')
    expect(after).not.toBe(before)
  })

  it('is stable when nothing structural changes', () => {
    expect(treeStructureKey([{ id: 'f1', count: 2 }], ['n1'], 'name-asc')).toBe(
      treeStructureKey([{ id: 'f1', count: 2 }], ['n1'], 'name-asc'),
    )
  })
})

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

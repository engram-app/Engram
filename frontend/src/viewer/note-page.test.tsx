import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, waitFor } from '@testing-library/react'
import * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'

const { openDoc, closeDoc, enroll, getCrdtSyncStatus, subscribeToCrdtSyncStatus } = vi.hoisted(() => ({
  openDoc: vi.fn(),
  closeDoc: vi.fn(),
  enroll: vi.fn(),
  getCrdtSyncStatus: vi.fn(() => 'synced' as const),
  subscribeToCrdtSyncStatus: vi.fn(() => () => {}),
}))

vi.mock('../crdt/session', () => ({ openDoc, closeDoc, enroll, getCrdtSyncStatus, subscribeToCrdtSyncStatus }))

const useNoteMock = vi.fn()
vi.mock('../api/queries', () => ({ useNote: (...a: unknown[]) => useNoteMock(...a) }))
vi.mock('react-router', () => ({ useParams: () => ({ id: 'note-1' }) }))
// Minimal stubs for the right-sidebar + lazy editor context used by the page.
vi.mock('../layout/right-sidebar-context', () => ({
  useRightSidebar: () => ({ setContent: () => {} }),
}))

import NotePage from './note-page'

const NOTE = {
  id: 'note-1',
  path: 'folder/note.md',
  title: 'note',
  folder: 'folder',
  content: '# hi',
  tags: [],
  version: 1,
}

describe('NotePage (CRDT)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    const doc = new Y.Doc()
    openDoc.mockResolvedValue({
      ytext: doc.getText('content'),
      awareness: new Awareness(doc),
      doc,
    })
    useNoteMock.mockReturnValue({ data: NOTE, isLoading: false, error: null })
  })

  it('opens + enrolls the CRDT doc for a .md note', async () => {
    render(<NotePage />)
    await waitFor(() => expect(openDoc).toHaveBeenCalledWith('folder/note.md'))
    expect(enroll).toHaveBeenCalledWith('folder/note.md')
  })

  it('closes the doc on unmount', async () => {
    const { unmount } = render(<NotePage />)
    await waitFor(() => expect(openDoc).toHaveBeenCalled())
    unmount()
    expect(closeDoc).toHaveBeenCalledWith('folder/note.md')
  })
})

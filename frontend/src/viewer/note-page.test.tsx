import { describe, expect, it, vi, beforeEach } from 'vitest'
import { forwardRef, useImperativeHandle } from 'react'
import { act, fireEvent, render, screen } from '@testing-library/react'
import type { NoteChangedPayload } from '../api/channel'

// --- module mocks: isolate the SURFACE (no Save/Revert, toggle, editor) ---
vi.mock('react-router', () => ({
  useParams: () => ({ id: 'n1' }),
}))

const note = {
  id: 'n1',
  path: 'a.md',
  title: 'A',
  folder: '',
  tags: [],
  version: 1,
  mtime: '2026-06-13T00:00:00Z',
  created_at: '2026-06-13T00:00:00Z',
  updated_at: '2026-06-13T00:00:00Z',
  content: 'hello',
}

const onEditSpy = vi.fn()
vi.mock('../api/queries', () => ({
  useNote: () => ({ data: note, isLoading: false, error: null }),
  useSaveNoteContent: () => vi.fn().mockResolvedValue(2),
  useFetchNoteFresh: () => vi.fn().mockResolvedValue(note),
}))

vi.mock('../api/active-vault', () => ({ useActiveVaultId: () => 'v1' }))

// Capture the channel subscriber so a test can fire a remote change.
let fireRemote: ((p: NoteChangedPayload) => void) | null = null
vi.mock('../api/channel', () => ({
  subscribeToNoteChanges: (cb: (p: NoteChangedPayload) => void) => {
    fireRemote = cb
    return () => {
      fireRemote = null
    }
  },
}))

vi.mock('../layout/right-sidebar-context', () => ({
  useRightSidebar: () => ({ setContent: vi.fn() }),
}))

// Editor mock: forwards the imperative handle (getDoc/applyRemote) note-page
// drives, surfaces its `value` prop, and can fire an edit. `editorDoc` is the
// live CodeMirror doc; tests set it to stage a local draft.
let editorDoc = 'hello'
const appliedRemote: string[] = []
vi.mock('./note-editor', () => ({
  default: forwardRef(
    (props: { value: string; onChange: (v: string) => void }, ref) => {
      useImperativeHandle(ref, () => ({
        getDoc: () => editorDoc,
        applyRemote: (t: string) => {
          editorDoc = t
          appliedRemote.push(t)
        },
      }))
      return (
        <div data-testid="cm-editor">
          <span data-testid="cm-value">{props.value}</span>
          <button type="button" onClick={() => props.onChange('PASTED')}>
            sim-edit
          </button>
        </div>
      )
    },
  ),
}))

vi.mock('./note-view', () => ({ default: () => <div data-testid="note-view" /> }))
vi.mock('./note-toc', () => ({ default: () => <div data-testid="note-toc" /> }))

import NotePage from './note-page'

beforeEach(() => {
  fireRemote = null
  editorDoc = 'hello'
  appliedRemote.length = 0
  onEditSpy.mockReset()
})

function remote(content: string, version = 2): NoteChangedPayload {
  return { event_type: 'upsert', id: 'n1', path: 'a.md', vault_id: 'v1', content, version }
}

describe('NotePage surface', () => {
  it('renders the editor by default with no Save or Revert button', async () => {
    render(<NotePage />)
    expect(await screen.findByTestId('cm-editor')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /save/i })).toBeNull()
    expect(screen.queryByRole('button', { name: /revert/i })).toBeNull()
  })

  it('shows a Reading-view toggle', async () => {
    render(<NotePage />)
    await screen.findByTestId('cm-editor')
    expect(screen.getByRole('button', { name: /reading view/i })).toBeInTheDocument()
  })

  it('preserves unsaved edits when toggling to reading view and back', async () => {
    render(<NotePage />)
    await screen.findByTestId('cm-editor')
    expect(screen.getByTestId('cm-value')).toHaveTextContent('hello')

    // Simulate a paste/edit, then round-trip through the reading view.
    fireEvent.click(screen.getByRole('button', { name: /sim-edit/i }))
    fireEvent.click(screen.getByRole('button', { name: /reading view/i }))
    fireEvent.click(screen.getByRole('button', { name: /edit/i }))

    // The remounted editor must come back with the edited content, not the
    // stale per-note initial value.
    await screen.findByTestId('cm-editor')
    expect(screen.getByTestId('cm-value')).toHaveTextContent('PASTED')
  })
})

describe('NotePage conflict resolution', () => {
  it('a clean remote merge applies silently — no conflict bar', async () => {
    render(<NotePage />)
    await screen.findByTestId('cm-editor')
    // No local divergence on the changed region → clean merge.
    editorDoc = 'hello'

    act(() => fireRemote?.(remote('hello\n\nremote line')))

    expect(screen.queryByTestId('conflict-bar')).toBeNull()
    // The remote text was applied to the editor.
    expect(appliedRemote).toContain('hello\n\nremote line')
  })

  it('a conflicting remote change surfaces the bar WITHOUT clobbering the draft', async () => {
    render(<NotePage />)
    await screen.findByTestId('cm-editor')

    // Local draft diverges on the same line the remote also changes.
    editorDoc = 'hello mine'
    act(() => fireRemote?.(remote('hello theirs')))

    expect(await screen.findByTestId('conflict-bar')).toBeInTheDocument()
    // The draft must NOT be silently overwritten with remote/marker text.
    expect(appliedRemote).toEqual([])
    expect(editorDoc).toBe('hello mine')
  })

  it('Take theirs adopts the remote content and dismisses the bar', async () => {
    render(<NotePage />)
    await screen.findByTestId('cm-editor')
    editorDoc = 'hello mine'
    act(() => fireRemote?.(remote('hello theirs')))
    await screen.findByTestId('conflict-bar')

    fireEvent.click(screen.getByRole('button', { name: 'Take theirs' }))

    expect(screen.queryByTestId('conflict-bar')).toBeNull()
    expect(appliedRemote).toContain('hello theirs')
    expect(editorDoc).toBe('hello theirs')
  })

  it('View merge writes the marker text for manual cleanup', async () => {
    render(<NotePage />)
    await screen.findByTestId('cm-editor')
    editorDoc = 'hello mine'
    act(() => fireRemote?.(remote('hello theirs')))
    await screen.findByTestId('conflict-bar')

    fireEvent.click(screen.getByRole('button', { name: 'View merge' }))

    expect(screen.queryByTestId('conflict-bar')).toBeNull()
    // node-diff3 marker fences land in the applied text.
    const applied = appliedRemote[appliedRemote.length - 1] ?? ''
    expect(applied).toContain('<<<<<<<')
    expect(applied).toContain('>>>>>>>')
  })

  it('Keep mine dismisses the bar and leaves the draft in place', async () => {
    render(<NotePage />)
    await screen.findByTestId('cm-editor')
    editorDoc = 'hello mine'
    act(() => fireRemote?.(remote('hello theirs')))
    await screen.findByTestId('conflict-bar')

    fireEvent.click(screen.getByRole('button', { name: 'Keep mine' }))

    expect(screen.queryByTestId('conflict-bar')).toBeNull()
    expect(editorDoc).toBe('hello mine')
    // 'mine' is the resolution — remote was never applied over the draft.
    expect(appliedRemote).toEqual([])
  })
})

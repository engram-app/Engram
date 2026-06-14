import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'

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

vi.mock('../api/queries', () => ({
  useNote: () => ({ data: note, isLoading: false, error: null }),
  useSaveNoteContent: () => vi.fn().mockResolvedValue(2),
  useFetchNoteFresh: () => vi.fn().mockResolvedValue(note),
}))

vi.mock('../api/active-vault', () => ({ useActiveVaultId: () => 'v1' }))

vi.mock('../api/channel', () => ({ subscribeToNoteChanges: () => () => {} }))

vi.mock('../layout/right-sidebar-context', () => ({
  useRightSidebar: () => ({ setContent: vi.fn() }),
}))

// Editor mock that surfaces its `value` prop and can fire an edit, so we can
// assert what content the editor (re)mounts with across mode toggles.
vi.mock('./note-editor', () => ({
  default: (props: { value: string; onChange: (v: string) => void }) => (
    <div data-testid="cm-editor">
      <span data-testid="cm-value">{props.value}</span>
      <button type="button" onClick={() => props.onChange('PASTED')}>
        sim-edit
      </button>
    </div>
  ),
}))

vi.mock('./note-view', () => ({ default: () => <div data-testid="note-view" /> }))
vi.mock('./note-toc', () => ({ default: () => <div data-testid="note-toc" /> }))

import NotePage from './note-page'

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

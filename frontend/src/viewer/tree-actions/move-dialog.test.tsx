import { render, screen, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { MoveDialog } from './move-dialog'

const folders = [
  { name: '' }, // root
  { name: 'src' },
  { name: 'src/sub' },
  { name: 'docs' },
]

describe('MoveDialog', () => {
  it('lists all folders including root', () => {
    // Source file lives in `notes/` so all four folders (root, src, src/sub, docs)
    // are valid drop targets per isValidDropTarget (currentFolder='notes' ≠ any).
    render(<MoveDialog folders={folders} nodes={[{ kind: 'file', path: 'notes/a.md' }]} onPick={() => {}} onCancel={() => {}} />)
    expect(screen.getByText('/ (root)')).toBeInTheDocument()
    expect(screen.getByText('src')).toBeInTheDocument()
    expect(screen.getByText('src/sub')).toBeInTheDocument()
    expect(screen.getByText('docs')).toBeInTheDocument()
  })

  it('filters by typed query', () => {
    render(<MoveDialog folders={folders} nodes={[{ kind: 'file', path: 'a.md' }]} onPick={() => {}} onCancel={() => {}} />)
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'doc' } })
    expect(screen.getByText('docs')).toBeInTheDocument()
    expect(screen.queryByText('src')).not.toBeInTheDocument()
  })

  it('excludes the source folder when moving a folder into itself or descendant', () => {
    render(<MoveDialog folders={folders} nodes={[{ kind: 'folder', path: 'src' }]} onPick={() => {}} onCancel={() => {}} />)
    expect(screen.queryByText('src')).not.toBeInTheDocument()
    expect(screen.queryByText('src/sub')).not.toBeInTheDocument()
    expect(screen.getByText('docs')).toBeInTheDocument()
  })

  it('Enter calls onPick with highlighted folder', () => {
    const onPick = vi.fn()
    render(<MoveDialog folders={folders} nodes={[{ kind: 'file', path: 'a.md' }]} onPick={onPick} onCancel={() => {}} />)
    const input = screen.getByRole('combobox')
    fireEvent.change(input, { target: { value: 'docs' } })
    fireEvent.keyDown(input, { key: 'Enter' })
    expect(onPick).toHaveBeenCalledWith('docs')
  })

  it('shows "Move 3 items to…" heading when N>1', () => {
    render(
      <MoveDialog
        folders={folders}
        nodes={[
          { kind: 'file', path: 'a.md' },
          { kind: 'file', path: 'b.md' },
          { kind: 'file', path: 'c.md' },
        ]}
        onPick={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByText(/Move 3 items/i)).toBeInTheDocument()
  })

  it('intersects valid drop targets across all nodes when N>1', () => {
    // node1 sits in `src` → eligible: '', 'src/sub', 'docs' (not 'src')
    // node2 sits in `docs` → eligible: '', 'src', 'src/sub' (not 'docs')
    // intersection: '' (root), 'src/sub'
    render(
      <MoveDialog
        folders={folders}
        nodes={[
          { kind: 'file', path: 'src/a.md' },
          { kind: 'file', path: 'docs/b.md' },
        ]}
        onPick={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByText('/ (root)')).toBeInTheDocument()
    expect(screen.getByText('src/sub')).toBeInTheDocument()
    expect(screen.queryByText('src')).not.toBeInTheDocument()
    expect(screen.queryByText('docs')).not.toBeInTheDocument()
  })

  it('onPick receives target folder for batch', () => {
    const onPick = vi.fn()
    render(
      <MoveDialog
        folders={[{ name: 'Archive' }]}
        nodes={[
          { kind: 'file', path: 'a.md' },
          { kind: 'file', path: 'b.md' },
        ]}
        onPick={onPick}
        onCancel={() => {}}
      />,
    )
    fireEvent.click(screen.getByText('Archive'))
    expect(onPick).toHaveBeenCalledWith('Archive')
  })
})

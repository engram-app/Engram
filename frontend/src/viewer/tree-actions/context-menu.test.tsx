import { render, screen, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { ContextMenu } from './context-menu'
import { actionsFor } from './action-list'

describe('ContextMenu', () => {
  it('renders one button per action with destructive styling for delete', () => {
    render(<ContextMenu actions={actionsFor({ kind: 'file' })} position={{ x: 10, y: 10 }} onPick={() => {}} onClose={() => {}} />)
    expect(screen.getByRole('menuitem', { name: 'Rename' })).toBeInTheDocument()
    const del = screen.getByRole('menuitem', { name: 'Delete' })
    expect(del.className).toMatch(/text-red/)
  })

  it('click on item calls onPick with action id and closes', () => {
    const onPick = vi.fn()
    const onClose = vi.fn()
    render(<ContextMenu actions={actionsFor({ kind: 'file' })} position={{ x: 10, y: 10 }} onPick={onPick} onClose={onClose} />)
    fireEvent.click(screen.getByRole('menuitem', { name: 'Rename' }))
    expect(onPick).toHaveBeenCalledWith('rename')
    expect(onClose).toHaveBeenCalled()
  })

  it('Escape closes', () => {
    const onClose = vi.fn()
    render(<ContextMenu actions={actionsFor({ kind: 'file' })} position={{ x: 10, y: 10 }} onPick={() => {}} onClose={onClose} />)
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(onClose).toHaveBeenCalled()
  })
})

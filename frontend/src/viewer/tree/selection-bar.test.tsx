import { render, screen, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { SelectionBar } from './selection-bar'

describe('SelectionBar', () => {
  it('hidden when no selection', () => {
    const { container } = render(
      <SelectionBar count={0} onMove={vi.fn()} onDelete={vi.fn()} onCancel={vi.fn()} />,
    )
    expect(container.firstChild).toBeNull()
  })

  it('shows N in button labels', () => {
    render(<SelectionBar count={3} onMove={vi.fn()} onDelete={vi.fn()} onCancel={vi.fn()} />)
    expect(screen.getByRole('button', { name: /Move 3/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Delete 3/ })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Cancel/ })).toBeInTheDocument()
  })

  it('calls callbacks on click', () => {
    const onMove = vi.fn()
    const onDelete = vi.fn()
    const onCancel = vi.fn()
    render(<SelectionBar count={2} onMove={onMove} onDelete={onDelete} onCancel={onCancel} />)
    fireEvent.click(screen.getByRole('button', { name: /Move/ }))
    expect(onMove).toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: /Delete/ }))
    expect(onDelete).toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: /Cancel/ }))
    expect(onCancel).toHaveBeenCalled()
  })

  it('shows count label', () => {
    render(<SelectionBar count={7} onMove={vi.fn()} onDelete={vi.fn()} onCancel={vi.fn()} />)
    expect(screen.getByText(/7 selected/i)).toBeInTheDocument()
  })
})

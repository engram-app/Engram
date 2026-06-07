import { render, screen, fireEvent } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { DeleteConfirm } from './delete-confirm'

describe('DeleteConfirm', () => {
  it('renders file message + Delete + Cancel', () => {
    render(<DeleteConfirm node={{ kind: 'file', path: 'a.md' }} onConfirm={() => {}} onCancel={() => {}} />)
    expect(screen.getByText(/Delete a\.md\?/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Delete' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument()
  })

  it('renders folder message with item count', () => {
    render(
      <DeleteConfirm
        node={{ kind: 'folder', path: 'src', childCount: 4 }}
        onConfirm={() => {}}
        onCancel={() => {}}
      />,
    )
    expect(screen.getByText(/Delete src\/ and 4 items\?/)).toBeInTheDocument()
  })

  it('Delete button calls onConfirm', () => {
    const onConfirm = vi.fn()
    render(<DeleteConfirm node={{ kind: 'file', path: 'a.md' }} onConfirm={onConfirm} onCancel={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(onConfirm).toHaveBeenCalled()
  })

  it('Cancel button calls onCancel', () => {
    const onCancel = vi.fn()
    render(<DeleteConfirm node={{ kind: 'file', path: 'a.md' }} onConfirm={() => {}} onCancel={onCancel} />)
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(onCancel).toHaveBeenCalled()
  })
})

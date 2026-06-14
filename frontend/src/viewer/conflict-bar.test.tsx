import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { ConflictBar } from './conflict-bar'

function setup() {
  const onKeepMine = vi.fn()
  const onTakeTheirs = vi.fn()
  const onViewMerge = vi.fn()
  const onDismiss = vi.fn()
  render(
    <ConflictBar
      onKeepMine={onKeepMine}
      onTakeTheirs={onTakeTheirs}
      onViewMerge={onViewMerge}
      onDismiss={onDismiss}
    />,
  )
  return { onKeepMine, onTakeTheirs, onViewMerge, onDismiss }
}

describe('ConflictBar', () => {
  it('renders a non-blocking status bar with the three resolution actions', () => {
    setup()
    const bar = screen.getByTestId('conflict-bar')
    expect(bar).toHaveAttribute('role', 'status')
    expect(screen.getByRole('button', { name: 'Keep mine' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Take theirs' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'View merge' })).toBeInTheDocument()
  })

  it('fires onKeepMine', () => {
    const { onKeepMine } = setup()
    fireEvent.click(screen.getByRole('button', { name: 'Keep mine' }))
    expect(onKeepMine).toHaveBeenCalledTimes(1)
  })

  it('fires onTakeTheirs', () => {
    const { onTakeTheirs } = setup()
    fireEvent.click(screen.getByRole('button', { name: 'Take theirs' }))
    expect(onTakeTheirs).toHaveBeenCalledTimes(1)
  })

  it('fires onViewMerge', () => {
    const { onViewMerge } = setup()
    fireEvent.click(screen.getByRole('button', { name: 'View merge' }))
    expect(onViewMerge).toHaveBeenCalledTimes(1)
  })

  it('fires onDismiss from the ✕ button', () => {
    const { onDismiss } = setup()
    fireEvent.click(screen.getByRole('button', { name: 'Dismiss' }))
    expect(onDismiss).toHaveBeenCalledTimes(1)
  })
})

import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const restoreMutate = vi.fn()
const purgeMutate = vi.fn()
const deleted = [
  {
    id: 5,
    name: 'Old',
    description: null,
    slug: 'old',
    is_default: false,
    created_at: '',
    encrypted: true,
    deleted_at: '2026-05-28T00:00:00Z',
    purge_at: '2026-06-27T00:00:00Z',
  },
]
let activeCount = 1
const cap = 1

vi.mock('@/api/queries', () => ({
  useDeletedVaults: () => ({ data: deleted, isLoading: false }),
  useVaults: () => ({ data: new Array(activeCount).fill({ id: 99 }) }),
  useRestoreVault: () => ({ mutate: restoreMutate, isPending: false }),
  usePurgeVault: () => ({ mutate: purgeMutate, isPending: false }),
  useBillingConfig: () => ({ data: { vaults_cap: cap } }),
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { DeletedVaultsSection } from './deleted-vaults-section'

describe('DeletedVaultsSection', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    activeCount = 1
    // Reset the URL so ?highlight from one test doesn't leak into others.
    window.history.pushState({}, '', '/settings/vaults')
  })

  it('shows the purge date', () => {
    render(<DeletedVaultsSection />)
    expect(screen.getByText('Old')).toBeInTheDocument()
    expect(screen.getByText(/purges/i)).toBeInTheDocument()
  })

  it('disables restore when at the cap', () => {
    activeCount = 1 // cap is 1, so restoring would exceed
    render(<DeletedVaultsSection />)
    expect(screen.getByRole('button', { name: /restore/i })).toBeDisabled()
  })

  it('restores when under cap', async () => {
    activeCount = 0
    render(<DeletedVaultsSection />)
    const btn = screen.getByRole('button', { name: /restore/i })
    expect(btn).toBeEnabled()
    fireEvent.click(btn)
    await waitFor(() => expect(restoreMutate).toHaveBeenCalledWith(5, expect.anything()))
  })

  it('purges permanently when confirmed', async () => {
    window.confirm = vi.fn().mockReturnValue(true)
    render(<DeletedVaultsSection />)
    fireEvent.click(screen.getByRole('button', { name: /delete permanently/i }))
    await waitFor(() => expect(purgeMutate).toHaveBeenCalledWith(5, expect.anything()))
  })

  it('does not purge when confirmation is dismissed', () => {
    window.confirm = vi.fn().mockReturnValue(false)
    render(<DeletedVaultsSection />)
    fireEvent.click(screen.getByRole('button', { name: /delete permanently/i }))
    expect(purgeMutate).not.toHaveBeenCalled()
  })

  it('highlights the row matching ?highlight=<id>', () => {
    // jsdom: set the query param the component reads
    window.history.pushState({}, '', '/settings/vaults?highlight=5')
    render(<DeletedVaultsSection />)
    expect(screen.getByText('Old').closest('li')).toHaveAttribute('data-highlighted', 'true')
  })
})

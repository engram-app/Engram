import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const createMutate = vi.fn()
vi.mock('./vaults/active-vaults-section', () => ({ ActiveVaultsSection: () => <div>active-section</div> }))
vi.mock('./vaults/deleted-vaults-section', () => ({ DeletedVaultsSection: () => <div>deleted-section</div> }))
vi.mock('@/api/queries', () => ({ useCreateVault: () => ({ mutate: createMutate, isPending: false }) }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import VaultsPage from './vaults-page'

describe('VaultsPage', () => {
  beforeEach(() => vi.clearAllMocks())

  it('renders both sections and a header', () => {
    render(<VaultsPage />)
    expect(screen.getByRole('heading', { name: /vaults/i })).toBeInTheDocument()
    expect(screen.getByText('active-section')).toBeInTheDocument()
    expect(screen.getByText('deleted-section')).toBeInTheDocument()
  })

  it('creates a new vault', async () => {
    render(<VaultsPage />)
    fireEvent.click(screen.getByRole('button', { name: /new vault/i }))
    fireEvent.change(screen.getByLabelText(/vault name/i), { target: { value: 'Research' } })
    fireEvent.click(screen.getByRole('button', { name: /^create$/i }))
    await waitFor(() => expect(createMutate).toHaveBeenCalledWith({ name: 'Research' }, expect.anything()))
  })
})

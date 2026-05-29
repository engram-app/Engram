import { render, screen, fireEvent, waitFor, within } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const deleteMutate = vi.fn()
const updateMutate = vi.fn()
const vaults = [
  { id: 1, name: 'Work', description: null, slug: 'work', is_default: true, created_at: '', encrypted: true },
  { id: 2, name: 'Personal', description: null, slug: 'personal', is_default: false, created_at: '', encrypted: true },
]

vi.mock('@/api/queries', () => ({
  useVaults: () => ({ data: vaults, isLoading: false }),
  useDeleteVault: () => ({ mutate: deleteMutate, isPending: false }),
  useUpdateVault: () => ({ mutate: updateMutate, isPending: false }),
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { ActiveVaultsSection } from './active-vaults-section'

describe('ActiveVaultsSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('lists vaults and marks the default', () => {
    render(<ActiveVaultsSection />)
    expect(screen.getByText('Work')).toBeInTheDocument()
    expect(screen.getByText('Personal')).toBeInTheDocument()
    expect(screen.getByText('Default')).toBeInTheDocument()
  })

  it('keeps delete disabled until the vault name is typed', async () => {
    render(<ActiveVaultsSection />)
    const workRow = within(screen.getByText('Work').closest('li') as HTMLElement)
    fireEvent.click(workRow.getByRole('button', { name: /^delete$/i }))
    const confirmBtn = screen.getByRole('button', { name: /delete vault/i })
    expect(confirmBtn).toBeDisabled()
    fireEvent.change(screen.getByLabelText(/type .*work.* to confirm/i), { target: { value: 'Work' } })
    expect(confirmBtn).toBeEnabled()
    fireEvent.click(confirmBtn)
    await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith(1, expect.anything()))
  })

  it('sets a non-default vault as default', () => {
    render(<ActiveVaultsSection />)
    fireEvent.click(screen.getByRole('button', { name: /set default/i }))
    expect(updateMutate).toHaveBeenCalledWith({ id: 2, is_default: true }, expect.anything())
  })
})

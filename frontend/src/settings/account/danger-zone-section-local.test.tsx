import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'

const { logout, deleteMutate, navigate } = vi.hoisted(() => ({
  logout: vi.fn(),
  deleteMutate: vi.fn(),
  navigate: vi.fn(),
}))

vi.mock('../../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ logout }),
}))
vi.mock('react-router', () => ({ useNavigate: () => navigate }))
vi.mock('../../api/queries', () => ({
  useDeleteSelf: () => ({ mutateAsync: deleteMutate, isPending: false }),
}))

import { DangerZoneSectionLocal } from './danger-zone-section-local'

beforeEach(() => {
  logout.mockReset().mockResolvedValue(undefined)
  deleteMutate.mockReset()
  navigate.mockReset()
})

describe('DangerZoneSectionLocal', () => {
  it('requires password and submits delete', async () => {
    deleteMutate.mockResolvedValueOnce(undefined)
    render(<DangerZoneSectionLocal />)

    fireEvent.click(screen.getByRole('button', { name: /delete account/i }))
    fireEvent.change(await screen.findByLabelText(/password/i), {
      target: { value: 'password123' },
    })
    fireEvent.click(screen.getByLabelText(/i understand/i))
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))

    await waitFor(() => expect(deleteMutate).toHaveBeenCalledWith({ password: 'password123' }))
    await waitFor(() => expect(logout).toHaveBeenCalled())
    await waitFor(() => expect(navigate).toHaveBeenCalledWith('/sign-in'))
  })

  it('shows last-admin error and does not log out', async () => {
    deleteMutate.mockRejectedValueOnce(new Error('last_admin'))
    render(<DangerZoneSectionLocal />)

    fireEvent.click(screen.getByRole('button', { name: /delete account/i }))
    fireEvent.change(await screen.findByLabelText(/password/i), {
      target: { value: 'password123' },
    })
    fireEvent.click(screen.getByLabelText(/i understand/i))
    fireEvent.click(screen.getByRole('button', { name: /^delete$/i }))

    expect(await screen.findByText(/only admin/i)).toBeInTheDocument()
    expect(logout).not.toHaveBeenCalled()
  })
})

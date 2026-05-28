import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

let user = makeUser()
vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { PasswordSection } from './password-section'

describe('PasswordSection', () => {
  beforeEach(() => { vi.clearAllMocks(); user = makeUser() })

  it('changes password with current + new when passwordEnabled', async () => {
    render(<PasswordSection />)
    fireEvent.change(screen.getByLabelText(/current password/i), { target: { value: 'old' } })
    fireEvent.change(screen.getByLabelText(/^new password/i), { target: { value: 'newpass123' } })
    fireEvent.click(screen.getByRole('button', { name: /update password/i }))
    await waitFor(() =>
      expect(user.updatePassword).toHaveBeenCalledWith({
        currentPassword: 'old',
        newPassword: 'newpass123',
        signOutOfOtherSessions: true,
      }),
    )
  })

  it('omits currentPassword when no password is set yet', async () => {
    user = makeUser({ passwordEnabled: false })
    render(<PasswordSection />)
    expect(screen.queryByLabelText(/current password/i)).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText(/^new password/i), { target: { value: 'newpass123' } })
    fireEvent.click(screen.getByRole('button', { name: /set password/i }))
    await waitFor(() =>
      expect(user.updatePassword).toHaveBeenCalledWith({
        newPassword: 'newpass123',
        signOutOfOtherSessions: true,
      }),
    )
  })
})

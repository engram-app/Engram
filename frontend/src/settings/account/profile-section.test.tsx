import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

const user = makeUser()
vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { ProfileSection } from './profile-section'

describe('ProfileSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('saves edited names via user.update', async () => {
    render(<ProfileSection />)
    fireEvent.change(screen.getByLabelText(/first name/i), { target: { value: 'Grace' } })
    fireEvent.click(screen.getByRole('button', { name: /save/i }))
    await waitFor(() =>
      expect(user.update).toHaveBeenCalledWith({ firstName: 'Grace', lastName: 'Lovelace' }),
    )
  })

  it('uploads an avatar via setProfileImage', async () => {
    render(<ProfileSection />)
    const file = new File(['x'], 'a.png', { type: 'image/png' })
    fireEvent.change(screen.getByLabelText(/profile image/i), { target: { files: [file] } })
    await waitFor(() => expect(user.setProfileImage).toHaveBeenCalledWith({ file }))
  })
})

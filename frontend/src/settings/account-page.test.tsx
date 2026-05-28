import { render, screen } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'
import { makeUser } from './account/section-test-helpers'

vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user: makeUser(), isLoaded: true }),
  useReverification: (fn: unknown) => fn,
  useSessionList: () => ({ isLoaded: true, sessions: [] }),
  useSession: () => ({ session: { id: 'sess_current' } }),
  useClerk: () => ({ signOut: vi.fn().mockResolvedValue({}) }),
}))
vi.mock('@clerk/clerk-react/errors', () => ({
  isClerkAPIResponseError: () => false,
  isReverificationCancelledError: () => false,
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import AccountPage from './account-page'

describe('AccountPage', () => {
  it('renders the section stack with no embedded Clerk UserProfile', () => {
    render(<AccountPage />)
    expect(screen.getByRole('heading', { name: 'Account', level: 1 })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Profile' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Password' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /danger zone/i })).toBeInTheDocument()
  })
})

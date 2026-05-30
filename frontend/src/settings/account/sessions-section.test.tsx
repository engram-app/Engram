import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const current = { id: 'sess_current', latestActivity: { deviceType: 'Mac', browserName: 'Chrome' }, revoke: vi.fn() }
const other = { id: 'sess_other', latestActivity: { deviceType: 'iPhone', browserName: 'Safari' }, revoke: vi.fn().mockResolvedValue({}) }

vi.mock('@clerk/react', () => ({
  useSessionList: () => ({ isLoaded: true, sessions: [current, other] }),
  useSession: () => ({ session: { id: 'sess_current' } }),
}))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { SessionsSection } from './sessions-section'

describe('SessionsSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('marks the current session and hides its revoke button', () => {
    render(<SessionsSection />)
    expect(screen.getByText(/current/i)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /revoke sess_current/i })).not.toBeInTheDocument()
  })

  it('revokes another session', async () => {
    render(<SessionsSection />)
    fireEvent.click(screen.getByRole('button', { name: /revoke .*iphone/i }))
    await waitFor(() => expect(other.revoke).toHaveBeenCalled())
  })
})

import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

const googleAcct = { id: 'ext_1', provider: 'google', emailAddress: 'ada@gmail.com', destroy: vi.fn().mockResolvedValue({}) }
let user = makeUser({ externalAccounts: [googleAcct] })

vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { ConnectedAccountsSection } from './connected-accounts-section'

describe('ConnectedAccountsSection', () => {
  beforeEach(() => { vi.clearAllMocks(); user = makeUser({ externalAccounts: [googleAcct] }) })

  it('lists connected accounts and disconnects via destroy', async () => {
    render(<ConnectedAccountsSection providers={['oauth_google', 'oauth_github']} />)
    expect(screen.getByText(/ada@gmail.com/i)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /disconnect google/i }))
    await waitFor(() => expect(googleAcct.destroy).toHaveBeenCalled())
  })

  it('connects a new provider via createExternalAccount', async () => {
    render(<ConnectedAccountsSection providers={['oauth_github']} />)
    fireEvent.click(screen.getByRole('button', { name: /connect github/i }))
    await waitFor(() =>
      expect(user.createExternalAccount).toHaveBeenCalledWith(
        expect.objectContaining({ strategy: 'oauth_github' }),
      ),
    )
  })
})

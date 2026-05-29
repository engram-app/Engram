import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import OAuthAuthorizePage from './oauth-authorize-page'

const { fetchOAuthClient, postOAuthConsent } = vi.hoisted(() => ({
  fetchOAuthClient: vi.fn(),
  postOAuthConsent: vi.fn(),
}))

vi.mock('../api/oauth', () => ({ fetchOAuthClient, postOAuthConsent }))

vi.mock('../api/queries', () => ({
  useMe: () => ({ data: { email: 'todd@example.com' }, isLoading: false }),
  useVaults: () => ({
    data: [
      { id: 1, name: 'Personal' },
      { id: 2, name: 'Work' },
    ],
    isLoading: false,
  }),
}))

vi.mock('../theme/theme-toggle', () => ({
  default: () => <button type="button">theme</button>,
}))

const VALID_QS =
  '?client_id=cli&redirect_uri=https://app/cb&response_type=code' +
  '&code_challenge=abc&code_challenge_method=S256&state=xyz&scope=vault.read'

function renderAt(qs: string) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[`/oauth/consent${qs}`]}>
        <OAuthAuthorizePage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

afterEach(() => {
  vi.clearAllMocks()
})

describe('OAuthAuthorizePage', () => {
  it('renders the consent prompt with client name and signed-in email', async () => {
    fetchOAuthClient.mockResolvedValue({ client_id: 'cli', client_name: 'Claude Desktop' })
    renderAt(VALID_QS)
    expect(await screen.findByText(/Claude Desktop/)).toBeInTheDocument()
    expect(screen.getByText(/signed in as todd@example.com/i)).toBeInTheDocument()
  })

  it('shows the invalid-request alert when a required param is missing', () => {
    renderAt('?client_id=cli')
    expect(
      screen.getByRole('heading', { name: /invalid authorization request/i }),
    ).toBeInTheDocument()
  })

  it('shows the unknown-client alert when the client lookup fails', async () => {
    fetchOAuthClient.mockRejectedValue(new Error('oauth client lookup failed: 404'))
    renderAt(VALID_QS)
    expect(await screen.findByText(/unknown oauth client/i)).toBeInTheDocument()
  })

  it('submits consent with the chosen vault and redirects', async () => {
    fetchOAuthClient.mockResolvedValue({ client_id: 'cli', client_name: 'Claude Desktop' })
    postOAuthConsent.mockResolvedValue({ redirect_uri: 'https://app/cb?code=ok' })
    const assign = vi.spyOn(window.location, 'assign').mockImplementation(() => {})

    renderAt(VALID_QS)
    fireEvent.click(await screen.findByRole('radio', { name: /work/i }))
    fireEvent.click(screen.getByRole('button', { name: /approve/i }))

    await waitFor(() =>
      expect(postOAuthConsent).toHaveBeenCalledWith(
        expect.objectContaining({ client_id: 'cli', vault_choice: 'vault:2' }),
      ),
    )
    await waitFor(() => expect(assign).toHaveBeenCalledWith('https://app/cb?code=ok'))
  })

  it('cancels by redirecting back with access_denied', async () => {
    fetchOAuthClient.mockResolvedValue({ client_id: 'cli', client_name: 'Claude Desktop' })
    const assign = vi.spyOn(window.location, 'assign').mockImplementation(() => {})

    renderAt(VALID_QS)
    fireEvent.click(await screen.findByRole('button', { name: /cancel/i }))

    expect(assign).toHaveBeenCalledWith('https://app/cb?error=access_denied&state=xyz')
  })
})

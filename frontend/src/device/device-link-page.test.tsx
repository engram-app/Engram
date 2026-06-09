import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import DeviceLinkPage from './device-link-page'

const { get, post } = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }))
vi.mock('../api/client', () => ({ api: { get, post } }))

const { setActiveVaultId } = vi.hoisted(() => ({ setActiveVaultId: vi.fn() }))
vi.mock('../api/active-vault', () => ({ setActiveVaultId }))

const authState = vi.hoisted(() => ({ current: { isSignedIn: true } as { isSignedIn: boolean } }))
vi.mock('../auth/use-auth-adapter', () => ({ useAuthAdapter: () => authState.current }))

vi.mock('../theme/theme-toggle', () => ({
  default: () => <button type="button">theme</button>,
}))

// The /link page now reads /billing/status to drive the proactive cap UI.
// Default: unlimited (atCap=false) so existing tests still see the normal flow.
type FakeBilling = {
  caps: { obsidian_connections: number | null; mcp_connections: number | null; api_write_enabled: boolean }
  current_connections: { obsidian: number; mcp: number }
}
const billingState = vi.hoisted(() => ({
  current: {
    caps: { obsidian_connections: null, mcp_connections: null, api_write_enabled: true },
    current_connections: { obsidian: 0, mcp: 0 },
  } as FakeBilling,
}))
vi.mock('../api/queries', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api/queries')>()
  return {
    ...actual,
    useBillingStatus: () => ({ data: billingState.current }),
    useMe: () => ({ data: { id: 1, email: 'me@example.com' } }),
    // The cap panel reads this — keep it deterministic across tests so we
    // don't trigger real network fetches via the partial-mock pass-through.
    useConnections: () => ({
      data: [
        {
          kind: 'obsidian',
          client_id: null,
          key_id: 42,
          name: 'Old laptop',
          software_id: null,
          software_version: null,
          verified: false,
          logo: null,
          vault_id: 1,
          vault_name: 'Personal',
          scope: null,
          last_used_at: null,
          connected_at: null,
          first_user_agent: null,
          first_ip: null,
          redirect_uris: [],
        },
      ],
      isLoading: false,
    }),
  }
})

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <DeviceLinkPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

afterEach(() => {
  vi.clearAllMocks()
  authState.current = { isSignedIn: true }
  billingState.current = {
    caps: { obsidian_connections: null, mcp_connections: null, api_write_enabled: true },
    current_connections: { obsidian: 0, mcp: 0 },
  }
})

describe('DeviceLinkPage', () => {
  it('shows a sign-in prompt when signed out', () => {
    authState.current = { isSignedIn: false }
    renderPage()
    expect(screen.getByText(/sign in to link/i)).toBeInTheDocument()
  })

  it('rejects a code that is not 8 characters', () => {
    renderPage()
    fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/i), { target: { value: 'ABC' } })
    fireEvent.click(screen.getByRole('button', { name: /verify/i }))
    expect(screen.getByRole('alert')).toHaveTextContent(/8 characters/i)
    expect(get).not.toHaveBeenCalled()
  })

  it('verifies a valid code and authorizes the chosen vault', async () => {
    get.mockResolvedValue({ vaults: [{ id: 7, name: 'Personal', note_count: 12 }] })
    post.mockResolvedValue({ ok: true, vault_id: 7 })
    renderPage()

    fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/i), { target: { value: 'ENGR7X4K' } })
    fireEvent.click(screen.getByRole('button', { name: /verify/i }))

    fireEvent.click(await screen.findByRole('radio', { name: /personal/i }))
    fireEvent.click(screen.getByRole('button', { name: /^sync$/i }))

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith(
        '/auth/device/authorize',
        expect.objectContaining({ user_code: 'ENGR-7X4K', vault_id: 7 }),
      ),
    )
    expect(await screen.findByText(/vault linked/i)).toBeInTheDocument()
  })

  it('forwards to the linked vault (sets it active) after authorizing', async () => {
    get.mockResolvedValue({
      vaults: [
        { id: 7, name: 'Personal', note_count: 12 },
        { id: 9, name: 'Work', note_count: 3 },
      ],
    })
    post.mockResolvedValue({ ok: true, vault_id: 9 })
    renderPage()

    fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/i), { target: { value: 'ENGR7X4K' } })
    fireEvent.click(screen.getByRole('button', { name: /verify/i }))

    fireEvent.click(await screen.findByRole('radio', { name: /work/i }))
    fireEvent.click(screen.getByRole('button', { name: /^sync$/i }))

    await waitFor(() => expect(setActiveVaultId).toHaveBeenCalledWith(9))
  })

  it('shows the heads-up banner (but keeps the code input) when at the Obsidian cap', () => {
    // Free-tier user already syncing one Obsidian device — landing on /link
    // shows a banner explaining the swap (this device will replace the existing
    // one), but the code input stays visible so they can still proceed.
    billingState.current = {
      caps: { obsidian_connections: 1, mcp_connections: 1, api_write_enabled: true },
      current_connections: { obsidian: 1, mcp: 0 },
    }
    renderPage()
    expect(screen.getByRole('status')).toHaveTextContent(/heads up/i)
    expect(screen.getByRole('status')).toHaveTextContent(/will disconnect/i)
    expect(screen.getByPlaceholderText(/XXXX-XXXX/i)).toBeInTheDocument()
  })
})

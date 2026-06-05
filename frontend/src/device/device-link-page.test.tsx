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
})

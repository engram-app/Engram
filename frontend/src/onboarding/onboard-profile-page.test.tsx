import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import OnboardProfilePage from './onboard-profile-page'

const { mutate, navigate } = vi.hoisted(() => ({
  mutate: vi.fn().mockResolvedValue({
    uses_obsidian: false,
    tools: ['claude'],
    completed_at: 'now',
  }),
  navigate: vi.fn(),
}))

vi.mock('../api/queries', () => ({
  useSetOnboardingProfile: () => ({ mutateAsync: mutate, isPending: false, error: null }),
}))

vi.mock('react-router', async () => {
  const actual = await vi.importActual<typeof import('react-router')>('react-router')
  return { ...actual, useNavigate: () => navigate }
})

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <OnboardProfilePage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('OnboardProfilePage', () => {
  beforeEach(() => {
    mutate.mockClear()
    navigate.mockClear()
  })

  it('starts on the Obsidian question', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: /where do your notes live/i })).toBeInTheDocument()
  })

  it('moves to tools screen after picking a path', () => {
    renderPage()
    fireEvent.click(screen.getByRole('button', { name: /starting fresh/i }))
    expect(screen.getByRole('heading', { name: /how will you use engram/i })).toBeInTheDocument()
  })

  it('disables Take me to my vault until at least one tool is selected', () => {
    renderPage()
    fireEvent.click(screen.getByRole('button', { name: /starting fresh/i }))
    const submit = screen.getByRole('button', { name: /continue/i })
    expect(submit).toBeDisabled()
    fireEvent.click(screen.getByRole('checkbox', { name: /claude code/i }))
    expect(submit).not.toBeDisabled()
  })

  it('submits selected uses_obsidian + tools, then routes to /onboard/vault', async () => {
    renderPage()
    fireEvent.click(screen.getByRole('button', { name: /already use obsidian/i }))
    fireEvent.click(screen.getByRole('checkbox', { name: /^claude \(/i }))
    fireEvent.click(screen.getByRole('checkbox', { name: /cursor/i }))
    fireEvent.click(screen.getByRole('button', { name: /continue/i }))

    await waitFor(() => expect(mutate).toHaveBeenCalledTimes(1))
    expect(mutate).toHaveBeenCalledWith({
      uses_obsidian: true,
      tools: ['claude', 'cursor'],
    })
    expect(navigate).toHaveBeenCalledWith('/onboard/vault', { replace: true })
  })

  it('Back button on screen 2 returns to screen 1', () => {
    renderPage()
    fireEvent.click(screen.getByRole('button', { name: /starting fresh/i }))
    fireEvent.click(screen.getByRole('button', { name: /back/i }))
    expect(screen.getByRole('heading', { name: /where do your notes live/i })).toBeInTheDocument()
  })
})

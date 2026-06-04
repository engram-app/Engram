import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router'
import OnboardLayout from './onboard-layout'

const logout = vi.fn()

vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ logout }),
}))

vi.mock('../theme/theme-toggle', () => ({
  default: () => null,
}))

vi.mock('../api/queries', () => ({
  useOnboardingStatus: vi.fn(),
}))

import { useOnboardingStatus } from '../api/queries'

type Steps = ('agreement' | 'billing' | 'profile' | 'vault')[]

function renderAt(path: string, steps: Steps) {
  vi.mocked(useOnboardingStatus).mockReturnValue({
    data: { enabled: true, next_step: 'profile', steps },
    isLoading: false,
    isError: false,
  } as never)

  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route element={<OnboardLayout />}>
          <Route path="/onboard/agreement" element={<p>agreement step</p>} />
          <Route path="/onboard/billing" element={<p>billing step</p>} />
          <Route path="/onboard/profile" element={<p>profile step</p>} />
          <Route path="/onboard/vault" element={<p>vault step</p>} />
        </Route>
        <Route path="/onboard" element={<p>resolver landing</p>} />
      </Routes>
    </MemoryRouter>,
  )
}

const SAAS: Steps = ['agreement', 'billing', 'profile', 'vault']
const SELF: Steps = ['profile', 'vault']

describe('OnboardLayout', () => {
  it('renders loading screen while status is pending', () => {
    vi.mocked(useOnboardingStatus).mockReturnValue({
      data: undefined,
      isLoading: true,
      isError: false,
    } as never)
    render(
      <MemoryRouter initialEntries={['/onboard/profile']}>
        <Routes>
          <Route element={<OnboardLayout />}>
            <Route path="/onboard/profile" element={<p>profile step</p>} />
          </Route>
        </Routes>
      </MemoryRouter>,
    )
    expect(screen.getByText(/loading/i)).toBeInTheDocument()
  })

  it('numbers each hosted step 1-of-4 through 4-of-4', () => {
    renderAt('/onboard/agreement', SAAS)
    expect(screen.getByText(/step 1 of 4/i)).toBeInTheDocument()
  })

  it('shows step 2 of 4 on billing (hosted)', () => {
    renderAt('/onboard/billing', SAAS)
    expect(screen.getByText(/step 2 of 4/i)).toBeInTheDocument()
    expect(screen.getByText('billing step')).toBeInTheDocument()
  })

  it('shows step 3 of 4 on profile (hosted)', () => {
    renderAt('/onboard/profile', SAAS)
    expect(screen.getByText(/step 3 of 4/i)).toBeInTheDocument()
  })

  it('shows step 4 of 4 on vault (hosted)', () => {
    renderAt('/onboard/vault', SAAS)
    expect(screen.getByText(/step 4 of 4/i)).toBeInTheDocument()
  })

  it('shows step 1 of 2 on profile (self-host)', () => {
    renderAt('/onboard/profile', SELF)
    expect(screen.getByText(/step 1 of 2/i)).toBeInTheDocument()
  })

  it('shows step 2 of 2 on vault (self-host)', () => {
    renderAt('/onboard/vault', SELF)
    expect(screen.getByText(/step 2 of 2/i)).toBeInTheDocument()
  })

  it('shows step 1 of 1 when obsidian short-circuit drops vault', () => {
    renderAt('/onboard/profile', ['profile'])
    expect(screen.getByText(/step 1 of 1/i)).toBeInTheDocument()
  })

  it('redirects /onboard/agreement to /onboard when self-host chain skips it', () => {
    renderAt('/onboard/agreement', SELF)
    expect(screen.getByText('resolver landing')).toBeInTheDocument()
  })

  it('redirects /onboard/billing to /onboard when self-host chain skips it', () => {
    renderAt('/onboard/billing', SELF)
    expect(screen.getByText('resolver landing')).toBeInTheDocument()
  })

  it('redirects /onboard/vault to /onboard when uses_obsidian drops the vault step', () => {
    renderAt('/onboard/vault', ['profile'])
    expect(screen.getByText('resolver landing')).toBeInTheDocument()
  })

  it('signs the user out mid-flow', () => {
    renderAt('/onboard/profile', SAAS)
    fireEvent.click(screen.getByRole('button', { name: /sign out/i }))
    expect(logout).toHaveBeenCalled()
  })
})

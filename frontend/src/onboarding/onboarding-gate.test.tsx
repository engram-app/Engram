import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import OnboardingGate from './onboarding-gate'

vi.mock('../api/queries', () => ({
  useAppBootstrap: vi.fn(),
}))

import { useAppBootstrap } from '../api/queries'

// The gate reads onboarding state out of the consolidated bootstrap payload, so
// wrap each onboarding status under `data.onboarding`.
function renderWith(onboarding: unknown, rest: Record<string, unknown> = {}) {
  vi.mocked(useAppBootstrap).mockReturnValue({
    data: onboarding == null ? undefined : { onboarding },
    isLoading: false,
    isError: false,
    ...rest,
  } as never)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={['/']}>
        <Routes>
          <Route element={<OnboardingGate />}>
            <Route path="/" element={<div>dashboard</div>} />
          </Route>
          <Route path="/onboard/agreement" element={<div>agreement-step</div>} />
          <Route path="/onboard/billing" element={<div>billing-step</div>} />
          <Route path="/onboard/tools" element={<div>tools-step</div>} />
          <Route path="/onboard/vault" element={<div>vault-step</div>} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('OnboardingGate', () => {
  it('renders loading state while bootstrap query is pending', () => {
    renderWith(null, { isLoading: true })
    expect(screen.getByText(/loading/i)).toBeInTheDocument()
  })

  it('renders children when next_step is done', () => {
    renderWith({ enabled: true, next_step: 'done', terms_ok: true, subscription_ok: true })
    expect(screen.getByText('dashboard')).toBeInTheDocument()
  })

  it('renders children when wizard is disabled (self-host)', () => {
    renderWith({ enabled: false, next_step: 'done' })
    expect(screen.getByText('dashboard')).toBeInTheDocument()
  })

  it('redirects to /onboard/agreement when next_step=agreement', () => {
    renderWith({
      enabled: true,
      next_step: 'agreement',
      terms_ok: false,
      subscription_ok: false,
    })
    expect(screen.getByText('agreement-step')).toBeInTheDocument()
  })

  it('redirects to /onboard/billing when next_step=billing', () => {
    renderWith({
      enabled: true,
      next_step: 'billing',
      terms_ok: true,
      subscription_ok: false,
    })
    expect(screen.getByText('billing-step')).toBeInTheDocument()
  })

  it('redirects to /onboard/tools when next_step=tools', () => {
    renderWith({
      enabled: true,
      next_step: 'tools',
      terms_ok: true,
      subscription_ok: true,
      profile_complete: false,
    })
    expect(screen.getByText('tools-step')).toBeInTheDocument()
  })

  it('redirects to /onboard/vault when next_step=vault', () => {
    renderWith({
      enabled: true,
      next_step: 'vault',
      terms_ok: true,
      subscription_ok: true,
      profile_complete: false,
    })
    expect(screen.getByText('vault-step')).toBeInTheDocument()
  })
})

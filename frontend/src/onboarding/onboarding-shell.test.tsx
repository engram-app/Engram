import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement } from 'react'
import { MemoryRouter } from 'react-router'
import { OnboardingShell } from './onboarding-shell'

function renderShell(ui: ReactElement) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>{ui}</MemoryRouter>
    </QueryClientProvider>,
  )
}

const mockRecord = vi.fn(() => Promise.resolve())
vi.mock('./use-onboarding-actions', () => ({
  useOnboardingActions: () => ({
    isLoading: false,
    vaultCount: 0,
    has: () => false,
    hasTourDecision: false,
    record: mockRecord,
    recordAsync: mockRecord,
  }),
}))

// Driver.js touches the DOM in ways jsdom doesn't fully model; the TourController
// behaviour is exercised in its own test file. Stub it to a no-op here so the
// shell's flow can be asserted in isolation.
vi.mock('./tour/controller', () => ({
  TourController: () => null,
}))

describe('OnboardingShell', () => {
  beforeEach(() => {
    mockRecord.mockClear()
  })

  it('opens tour-offer modal, then vault modal after skip', async () => {
    renderShell(
      <OnboardingShell>
        <p>dashboard</p>
      </OnboardingShell>,
    )
    expect(
      screen.getByRole('heading', { name: /quick tour/i }),
    ).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /skip/i }))
    await act(async () => {})
    expect(mockRecord).toHaveBeenCalledWith('tour_offered_skipped')
    expect(
      screen.getByRole('heading', { name: /first vault/i }),
    ).toBeInTheDocument()
  })
})

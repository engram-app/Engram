import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router'
import type { BillingStatus, OnboardingStatus } from '../api/queries'

const mutateAsync = vi.fn().mockResolvedValue({})

let onboardingStatus: { data: OnboardingStatus | undefined; isLoading: boolean } = {
  data: {
    enabled: true,
    next_step: 'tools',
    steps: [],
    actions: [],
    vault_count: 0,
    profile: { uses_obsidian: false, tools: [] },
  } as OnboardingStatus,
  isLoading: false,
}

let billingStatus: { data: Partial<BillingStatus> | undefined; isLoading: boolean } = {
  data: { tier: 'free', active: false } as Partial<BillingStatus>,
  isLoading: false,
}

vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    useOnboardingStatus: () => onboardingStatus,
    useSetOnboardingProfile: () => ({
      mutateAsync,
      isPending: false,
      isError: false,
    }),
    useBillingStatus: () => billingStatus,
  }
})

// Import after mocks
import OnboardToolsPage from './onboard-tools-page'

function wrap(ui: React.ReactNode) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return (
    <QueryClientProvider client={qc}>
      <MemoryRouter>{ui}</MemoryRouter>
    </QueryClientProvider>
  )
}

beforeEach(() => {
  mutateAsync.mockClear()
  onboardingStatus = {
    data: {
      enabled: true,
      next_step: 'tools',
      steps: [],
      actions: [],
      vault_count: 0,
      profile: { uses_obsidian: false, tools: [] },
    } as OnboardingStatus,
    isLoading: false,
  }
  billingStatus = {
    data: { tier: 'free', active: false } as Partial<BillingStatus>,
    isLoading: false,
  }
})

describe('OnboardToolsPage — Free tier', () => {
  it('shows the Free-tier banner with an Upgrade link to /settings/billing', () => {
    render(wrap(<OnboardToolsPage />))

    expect(screen.getByText(/free tier.*pick 1 to start/i)).toBeInTheDocument()
    const link = screen.getByRole('link', { name: /upgrade/i })
    expect(link).toHaveAttribute('href', '/settings/billing')
  })

  it('single-select: picking a second tool deselects the first', () => {
    render(wrap(<OnboardToolsPage />))

    // Click Claude first.
    const claude = screen.getByLabelText(/^Claude$/i)
    fireEvent.click(claude)
    expect(claude).toHaveAttribute('data-state', 'checked')

    // Then click Cursor — Claude should deselect.
    const cursor = screen.getByLabelText(/^Cursor$/i)
    fireEvent.click(cursor)
    expect(cursor).toHaveAttribute('data-state', 'checked')
    expect(claude).toHaveAttribute('data-state', 'unchecked')
  })
})

describe('OnboardToolsPage — Paid tier', () => {
  beforeEach(() => {
    billingStatus = {
      data: { tier: 'pro', active: true } as Partial<BillingStatus>,
      isLoading: false,
    }
  })

  it('does not render the Free banner', () => {
    render(wrap(<OnboardToolsPage />))
    expect(screen.queryByText(/free tier.*pick 1 to start/i)).toBeNull()
  })

  it('allows multi-select (no auto-deselect)', () => {
    render(wrap(<OnboardToolsPage />))

    const claude = screen.getByLabelText(/^Claude$/i)
    fireEvent.click(claude)
    const cursor = screen.getByLabelText(/^Cursor$/i)
    fireEvent.click(cursor)

    expect(claude).toHaveAttribute('data-state', 'checked')
    expect(cursor).toHaveAttribute('data-state', 'checked')
  })
})

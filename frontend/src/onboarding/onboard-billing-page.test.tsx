import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ThemeProvider } from '../theme/theme-provider'
import OnboardBillingPage from './onboard-billing-page'

vi.mock('@paddle/paddle-js', () => ({
  initializePaddle: vi.fn().mockResolvedValue(undefined),
  CheckoutEventNames: { CHECKOUT_COMPLETED: 'checkout.completed' },
}))

vi.mock('../api/queries', () => ({
  useOnboardingStatus: () => ({
    data: { enabled: true, next_step: 'billing' },
    isLoading: false,
  }),
  useBillingStatus: () => ({
    data: { tier: 'free', active: false, trial_days_remaining: 0, subscription: null },
    isLoading: false,
  }),
  useBillingConfig: () => ({
    data: {
      client_token: 'test_token',
      environment: 'sandbox',
      price_ids: {
        starter: { monthly: 'pri_starter_monthly', annual: 'pri_starter_annual' },
        pro: { monthly: 'pri_pro_monthly', annual: 'pri_pro_annual' },
      },
      customer_email: 'a@b.com',
      custom_data: { user_id: 1 },
    },
  }),
  useBillingSubscriptionDetail: () => ({ data: undefined }),
  useBillingHistory: () => ({ data: undefined }),
}))

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <ThemeProvider>
        <MemoryRouter>
          <OnboardBillingPage />
        </MemoryRouter>
      </ThemeProvider>
    </QueryClientProvider>,
  )
}

describe('OnboardBillingPage', () => {
  it('shows the plan choice with a recommended Pro plan for a free-tier user', () => {
    renderPage()
    expect(screen.getByRole('heading', { name: /choose your plan/i, level: 1 })).toBeInTheDocument()
    expect(screen.getByText('Starter')).toBeInTheDocument()
    expect(screen.getByText('Pro')).toBeInTheDocument()
    expect(screen.getByText(/most popular/i)).toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: /start free trial/i })).toHaveLength(2)
  })
})

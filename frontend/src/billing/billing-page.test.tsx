import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router'
import { ThemeProvider } from '../theme/theme-provider'

const initializePaddleMock = vi.fn()
vi.mock('@paddle/paddle-js', () => ({
  initializePaddle: (...args: unknown[]) => initializePaddleMock(...args),
  CheckoutEventNames: {
    CHECKOUT_LOADED: 'checkout.loaded',
    CHECKOUT_CLOSED: 'checkout.closed',
    CHECKOUT_COMPLETED: 'checkout.completed',
    CHECKOUT_PAYMENT_INITIATED: 'checkout.payment.initiated',
    CHECKOUT_PAYMENT_FAILED: 'checkout.payment.failed',
    CHECKOUT_PAYMENT_ERROR: 'checkout.payment.error',
    CHECKOUT_ERROR: 'checkout.error',
  },
}))

const { get } = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('../api/client', () => ({
  api: { get, post: vi.fn(), patch: vi.fn(), del: vi.fn() },
  setTokenGetter: vi.fn(),
}))

import BillingPage from './billing-page'

describe('BillingPage — Paddle effect cleanup', () => {
  beforeEach(() => {
    get.mockReset()
    initializePaddleMock.mockReset()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('Paddle effect cleanup: post-unmount eventCallback invocations are inert', async () => {
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status') return { tier: 'free', active: false, trial_days_remaining: 0, subscription: null, caps: {} }
      if (url === '/billing/config') return { client_token: 'tok', environment: 'sandbox', price_ids: { starter: { monthly: 'p1', annual: 'p2' }, pro: { monthly: 'p3', annual: 'p4' } }, customer_email: 'u@example.com', custom_data: { user_id: '1' }, vaults_cap: null }
      throw new Error(`unexpected GET ${url}`)
    })

    let captured: ((event: { name: string; data?: unknown }) => void) | undefined
    initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
      captured = opts.eventCallback
      return { Checkout: { open: vi.fn() } }
    })

    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { unmount } = render(
      <QueryClientProvider client={qc}>
        <ThemeProvider>
          <MemoryRouter>
            <BillingPage onActivated={() => {}} />
          </MemoryRouter>
        </ThemeProvider>
      </QueryClientProvider>,
    )

    // Wait for Paddle init — config query resolves async, then the useEffect
    // runs initializePaddle, which is itself async.
    await waitFor(() => expect(captured).toBeDefined())

    unmount()

    // A stale eventCallback firing after unmount must be a no-op (the
    // cancelled flag inside the effect short-circuits the switch).
    expect(() => captured!({ name: 'checkout.payment.initiated', data: { transaction_id: 'late' } })).not.toThrow()
  })
})

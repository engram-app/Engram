import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, waitFor } from '@testing-library/react'
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

  it('invalidates billing/status on activation for settings flow (no onActivated)', async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    let onboardingCalls = 0
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status') {
        return onboardingCalls === 0
          ? { tier: 'free', active: false, trial_days_remaining: 0, subscription: null, caps: {} }
          : { tier: 'starter', active: true, trial_days_remaining: 7, subscription: { status: 'trialing', tier: 'starter' }, caps: {} }
      }
      if (url === '/billing/config') {
        return { client_token: 'tok', environment: 'sandbox', price_ids: { starter: { monthly: 'p1', annual: 'p2' }, pro: { monthly: 'p3', annual: 'p4' } }, customer_email: 'u@example.com', custom_data: { user_id: '1' }, vaults_cap: null }
      }
      if (url === '/onboarding/status') {
        onboardingCalls += 1
        return onboardingCalls === 1
          ? { enabled: true, next_step: 'billing', subscription_ok: false, terms_ok: true, steps: ['agreement', 'billing', 'tools', 'vault'], actions: [], vault_count: 0 }
          : { enabled: true, next_step: 'done', subscription_ok: true, terms_ok: true, steps: ['agreement', 'billing', 'tools', 'vault'], actions: [], vault_count: 1 }
      }
      throw new Error(`unexpected GET ${url}`)
    })

    let captured: ((event: { name: string; data?: unknown }) => void) | undefined
    initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
      captured = opts.eventCallback
      return { Checkout: { open: vi.fn() } }
    })

    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')
    render(
      <QueryClientProvider client={qc}>
        <ThemeProvider>
          <MemoryRouter>
            {/* No onActivated — settings flow */}
            <BillingPage />
          </MemoryRouter>
        </ThemeProvider>
      </QueryClientProvider>,
    )

    await waitFor(() => expect(captured).toBeDefined())

    // Settings users get the watcher accelerated by PAYMENT_INITIATED too.
    await act(async () => {
      captured!({ name: 'checkout.payment.initiated', data: { transaction_id: 'txn_s1' } })
    })

    // Advance through accelerated poll cadence (1s); second poll returns
    // activated state and the watcher should invalidate ['billing','status'].
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })
    await act(async () => { await vi.advanceTimersByTimeAsync(1_000) })

    await waitFor(() => {
      const billingStatusInvalidations = invalidateSpy.mock.calls.filter(
        ([arg]) => {
          const key = (arg as { queryKey?: unknown[] })?.queryKey
          return Array.isArray(key) && key[0] === 'billing' && key[1] === 'status'
        },
      )
      expect(billingStatusInvalidations.length).toBeGreaterThan(0)
    })
  })
})

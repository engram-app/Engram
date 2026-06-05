import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router'
import { ThemeProvider } from '../theme/theme-provider'
import { AuthContext, type AuthAdapter } from '../auth/auth-context'

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

// Phoenix Socket mock — capture channel handlers. Hoisted so vi.mock factory
// can reference them. Constructor function (not arrow) so `new Socket(...)`
// works with vi.fn's Mock semantics.
const { channelHandlers, socketCtor } = vi.hoisted(() => {
  const channelHandlers: Record<string, (payload: unknown) => void> = {}
  const channelMock = {
    on: (event: string, cb: (payload: unknown) => void) => {
      channelHandlers[event] = cb
    },
    join: () => ({ receive: () => ({}) }),
  }
  const socketCtor = vi.fn(function MockSocket(this: object, ..._args: unknown[]) {
    Object.assign(this, {
      connect: vi.fn(),
      channel: vi.fn(() => channelMock),
      disconnect: vi.fn(),
    })
  })
  return { channelHandlers, socketCtor }
})
vi.mock('phoenix', () => ({ Socket: socketCtor }))

import BillingPage from './billing-page'

const authAdapter: AuthAdapter = {
  isLoaded: true,
  isSignedIn: true,
  user: { email: 'u@example.com' },
  getToken: async () => 'tok-test',
  logout: async () => {},
  hasBuiltInUI: false,
}

const ME = { id: 99, email: 'u@example.com', role: 'member' as const, display_name: null }

describe('BillingPage — Paddle effect cleanup', () => {
  beforeEach(() => {
    get.mockReset()
    initializePaddleMock.mockReset()
    socketCtor.mockClear()
    for (const k of Object.keys(channelHandlers)) delete channelHandlers[k]
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('Paddle effect cleanup: post-unmount eventCallback invocations are inert', async () => {
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status')
        return {
          tier: 'free',
          active: false,
          trial_days_remaining: 0,
          subscription: null,
          caps: {},
        }
      if (url === '/billing/config')
        return {
          client_token: 'tok',
          environment: 'sandbox',
          price_ids: {
            starter: { monthly: 'p1', annual: 'p2' },
            pro: { monthly: 'p3', annual: 'p4' },
          },
          customer_email: 'u@example.com',
          custom_data: { user_id: '1' },
          vaults_cap: null,
        }
      if (url === '/me') return { user: ME }
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
        <AuthContext.Provider value={authAdapter}>
          <ThemeProvider>
            <MemoryRouter>
              <BillingPage onActivated={() => {}} />
            </MemoryRouter>
          </ThemeProvider>
        </AuthContext.Provider>
      </QueryClientProvider>,
    )

    await waitFor(() => expect(captured).toBeDefined())

    unmount()

    expect(() =>
      captured!({ name: 'checkout.payment.initiated', data: { transaction_id: 'late' } }),
    ).not.toThrow()
  })

  it('invalidates billing/status on subscription_activated channel event (settings flow)', async () => {
    let billingActive = false
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status') {
        return billingActive
          ? {
              tier: 'starter',
              active: true,
              trial_days_remaining: 7,
              subscription: { status: 'trialing', tier: 'starter' },
              caps: {},
            }
          : {
              tier: 'free',
              active: false,
              trial_days_remaining: 0,
              subscription: null,
              caps: {},
            }
      }
      if (url === '/billing/config')
        return {
          client_token: 'tok',
          environment: 'sandbox',
          price_ids: {
            starter: { monthly: 'p1', annual: 'p2' },
            pro: { monthly: 'p3', annual: 'p4' },
          },
          customer_email: 'u@example.com',
          custom_data: { user_id: '1' },
          vaults_cap: null,
        }
      if (url === '/me') return { user: ME }
      throw new Error(`unexpected GET ${url}`)
    })

    initializePaddleMock.mockImplementation(async () => ({ Checkout: { open: vi.fn() } }))

    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const invalidateSpy = vi.spyOn(qc, 'invalidateQueries')
    render(
      <QueryClientProvider client={qc}>
        <AuthContext.Provider value={authAdapter}>
          <ThemeProvider>
            <MemoryRouter>
              {/* No onActivated — settings flow */}
              <BillingPage />
            </MemoryRouter>
          </ThemeProvider>
        </AuthContext.Provider>
      </QueryClientProvider>,
    )

    await waitFor(() => expect(channelHandlers['subscription_activated']).toBeDefined())

    billingActive = true
    await act(async () => {
      channelHandlers['subscription_activated']!({
        tier: 'starter',
        status: 'trialing',
        subscription_id: 'sub_settings',
      })
      await Promise.resolve()
    })

    await waitFor(() => {
      const billingStatusInvalidations = invalidateSpy.mock.calls.filter(([arg]) => {
        const key = (arg as { queryKey?: unknown[] })?.queryKey
        return Array.isArray(key) && key[0] === 'billing' && key[1] === 'status'
      })
      expect(billingStatusInvalidations.length).toBeGreaterThan(0)
    })
  })
})

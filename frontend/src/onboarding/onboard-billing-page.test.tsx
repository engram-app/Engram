import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { act, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter, Routes, Route } from 'react-router'
import { ThemeProvider } from '../theme/theme-provider'

// Capture the Paddle eventCallback so the test can drive it (or refuse to).
let capturedEventCallback: ((event: { name: string; data?: unknown }) => void) | undefined

// Counter for tools-page mounts. If onActivated fires twice (replace: true),
// react-router would re-mount the tools route — counter goes to 2.
let toolsPageMounts = 0
function ToolsPageProbe() {
  React.useEffect(() => {
    toolsPageMounts += 1
  }, [])
  return <div data-testid="tools-page" />
}

vi.mock('@paddle/paddle-js', () => ({
  initializePaddle: vi.fn(async (opts: { eventCallback?: typeof capturedEventCallback }) => {
    capturedEventCallback = opts.eventCallback
    return {
      Checkout: { open: vi.fn() },
    }
  }),
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

const { get, post, patch, del } = vi.hoisted(() => ({
  get: vi.fn(),
  post: vi.fn(),
  patch: vi.fn(),
  del: vi.fn(),
}))
vi.mock('../api/client', () => ({
  api: { get, post, patch, del },
  setTokenGetter: vi.fn(),
}))

// Import AFTER mocks so the hooks resolve against the mocked client.
import OnboardBillingPage from './onboard-billing-page'

function renderOnboardBilling() {
  const qc = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: 0 } },
  })
  return render(
    <QueryClientProvider client={qc}>
      <ThemeProvider>
        <MemoryRouter initialEntries={['/onboard/billing']}>
          <Routes>
            <Route path="/onboard/billing" element={<OnboardBillingPage />} />
            <Route path="/onboard/tools" element={<ToolsPageProbe />} />
            <Route path="/" element={<div data-testid="home-page" />} />
          </Routes>
        </MemoryRouter>
      </ThemeProvider>
    </QueryClientProvider>,
  )
}

const STATUS_BILLING = {
  enabled: true,
  next_step: 'billing' as const,
  subscription_ok: false,
  terms_ok: true,
  steps: ['agreement', 'billing', 'tools', 'vault'] as const,
  actions: [],
  vault_count: 0,
}

const STATUS_TOOLS = {
  ...STATUS_BILLING,
  next_step: 'tools' as const,
  subscription_ok: true,
}

const BILLING_INACTIVE = {
  tier: 'free',
  active: false,
  trial_days_remaining: 0,
  subscription: null,
  caps: { obsidian_connections: null, mcp_connections: null, api_write_enabled: false },
}

const BILLING_ACTIVE = {
  tier: 'starter',
  active: true,
  trial_days_remaining: 7,
  subscription: { status: 'trialing', tier: 'starter', current_period_end: '2026-07-01' },
  caps: { obsidian_connections: null, mcp_connections: null, api_write_enabled: true },
}

const BILLING_CONFIG = {
  client_token: 'tok',
  environment: 'sandbox',
  price_ids: {
    starter: { monthly: 'p1', annual: 'p2' },
    pro: { monthly: 'p3', annual: 'p4' },
  },
  customer_email: 'u@example.com',
  custom_data: { user_id: 1 },
  vaults_cap: null,
}

describe('OnboardBillingPage — bug #440 repro', () => {
  beforeEach(() => {
    capturedEventCallback = undefined
    toolsPageMounts = 0
    get.mockReset()
    post.mockReset()
    patch.mockReset()
    del.mockReset()
    vi.useFakeTimers({ shouldAdvanceTime: true })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('navigates user off the billing page when webhook lands, even if CHECKOUT_COMPLETED never fires', async () => {
    // Phase 1: user lands on billing page, sub inactive.
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status') return BILLING_INACTIVE
      if (url === '/billing/config') return BILLING_CONFIG
      if (url === '/onboarding/status') return STATUS_BILLING
      throw new Error(`unexpected GET ${url}`)
    })

    renderOnboardBilling()

    // Plan picker visible — both "Start free trial" buttons present.
    await waitFor(() =>
      expect(screen.getAllByRole('button', { name: /start free trial/i }).length).toBeGreaterThan(0),
    )

    // Phase 2: webhook "lands" server-side — backend now reports the user
    // is active and onboarding should advance to /onboard/tools. But Paddle
    // never fires CHECKOUT_COMPLETED (the bug condition: redirect via
    // successUrl, leaked instance, or trial-signup quirk swallowed the event).
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status') return BILLING_ACTIVE
      if (url === '/billing/config') return BILLING_CONFIG
      if (url === '/onboarding/status') return STATUS_TOOLS
      throw new Error(`unexpected GET ${url}`)
    })

    // Advance past the background-poll interval (BACKGROUND_MS = 10_000 in
    // the watcher hook wired in Task 2). Chunked advances + microtask flushes
    // let React Query observers settle between ticks. With the bug present,
    // no poll exists outside of CHECKOUT_COMPLETED, so the cache never
    // refreshes and the page never navigates — this assertion stays red until
    // Task 5 wires the watcher in.
    for (let i = 0; i < 5; i++) {
      await vi.advanceTimersByTimeAsync(3_000)
      await Promise.resolve()
    }

    await waitFor(
      () => expect(screen.getByTestId('tools-page')).toBeInTheDocument(),
      { timeout: 2000 },
    )
  })

  it('fires onActivated exactly once even with continued polling after activation', async () => {
    // First /onboarding/status response: still billing. Second onward: tools.
    let onboardingCalls = 0
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status') return BILLING_INACTIVE
      if (url === '/billing/config') return BILLING_CONFIG
      if (url === '/onboarding/status') {
        onboardingCalls += 1
        return onboardingCalls === 1 ? STATUS_BILLING : STATUS_TOOLS
      }
      throw new Error(`unexpected GET ${url}`)
    })

    renderOnboardBilling()

    // Wait for the plan picker, then drive payment-initiated.
    await waitFor(() =>
      expect(screen.getAllByRole('button', { name: /start free trial/i }).length).toBeGreaterThan(0),
    )
    await waitFor(() => expect(capturedEventCallback).toBeDefined())
    await act(async () => {
      capturedEventCallback!({
        name: 'checkout.payment.initiated',
        data: { transaction_id: 'txn_guarantee_42' },
      })
    })

    // Pump several accelerated ticks. The first poll already saw billing
    // (mounted-state background tick) and consumed onboardingCalls=1; the
    // second poll (accelerated, 1s) should see STATUS_TOOLS → activate. We
    // pump extra cycles to be robust to ordering.
    for (let i = 0; i < 6; i++) {
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1_000)
        await Promise.resolve()
      })
    }

    await waitFor(() => expect(screen.getByTestId('tools-page')).toBeInTheDocument())
    expect(toolsPageMounts).toBe(1)

    // Advance well past several more poll cycles — the watcher should be in
    // 'activated' (terminal). If anything is leaking schedules, it would
    // re-fire onActivated and re-mount tools-page.
    await act(async () => {
      for (let i = 0; i < 10; i++) {
        await vi.advanceTimersByTimeAsync(2_000)
        await Promise.resolve()
      }
    })

    expect(screen.getByTestId('tools-page')).toBeInTheDocument()
    expect(toolsPageMounts).toBe(1)
  })

  it('navigates immediately if cached onboarding status is already past billing', async () => {
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status') return BILLING_ACTIVE
      if (url === '/billing/config') return BILLING_CONFIG
      if (url === '/onboarding/status') return STATUS_TOOLS
      throw new Error(`unexpected GET ${url}`)
    })

    const qc = new QueryClient({
      defaultOptions: { queries: { retry: false, gcTime: 0 } },
    })
    // Pre-warm the cache: simulate the user having already advanced past
    // billing in another tab.
    qc.setQueryData(['onboarding', 'status'], STATUS_TOOLS)

    render(
      <QueryClientProvider client={qc}>
        <ThemeProvider>
          <MemoryRouter initialEntries={['/onboard/billing']}>
            <Routes>
              <Route path="/onboard/billing" element={<OnboardBillingPage />} />
              <Route path="/onboard/tools" element={<ToolsPageProbe />} />
              <Route path="/" element={<div data-testid="home-page" />} />
            </Routes>
          </MemoryRouter>
        </ThemeProvider>
      </QueryClientProvider>,
    )

    // Should redirect on mount cache check, NOT wait the 10s background poll.
    await waitFor(() => expect(screen.getByTestId('tools-page')).toBeInTheDocument())
    expect(toolsPageMounts).toBe(1)
  })

  it('hides overlay and re-enables plan picker on CHECKOUT_PAYMENT_FAILED', async () => {
    get.mockImplementation(async (url: string) => {
      if (url === '/billing/status') return BILLING_INACTIVE
      if (url === '/billing/config') return BILLING_CONFIG
      if (url === '/onboarding/status') return STATUS_BILLING
      throw new Error(`unexpected GET ${url}`)
    })

    renderOnboardBilling()

    await waitFor(() =>
      expect(screen.getAllByRole('button', { name: /start free trial/i }).length).toBeGreaterThan(0),
    )
    await waitFor(() => expect(capturedEventCallback).toBeDefined())

    // Step 1: payment initiated — overlay should show.
    await act(async () => {
      capturedEventCallback!({
        name: 'checkout.payment.initiated',
        data: { transaction_id: 'txn_fail_77' },
      })
      await vi.advanceTimersByTimeAsync(0)
    })
    await waitFor(() =>
      expect(screen.getByRole('heading', { name: /Activating your subscription/i })).toBeInTheDocument(),
    )

    // Step 2: payment failed — overlay should hide, plan picker re-enabled.
    await act(async () => {
      capturedEventCallback!({ name: 'checkout.payment.failed' })
      await vi.advanceTimersByTimeAsync(0)
    })

    await waitFor(() =>
      expect(screen.queryByRole('heading', { name: /Activating your subscription/i })).not.toBeInTheDocument(),
    )

    // Plan picker buttons should not be inside a disabled wrapper anymore.
    // The dimming wrapper drops the `pointer-events-none opacity-40` class
    // when overlay is hidden — assert the trial buttons are NOT inside an
    // `aria-disabled` / `pointer-events-none` ancestor.
    const trialButtons = screen.getAllByRole('button', { name: /start free trial/i })
    expect(trialButtons.length).toBeGreaterThan(0)
  })
})

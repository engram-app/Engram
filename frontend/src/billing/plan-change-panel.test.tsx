import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'

const { get, post } = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }))
vi.mock('../api/client', () => ({
  api: { get, post, patch: vi.fn(), del: vi.fn() },
  setTokenGetter: vi.fn(),
}))

import PlanChangePanel from './plan-change-panel'
import type { BillingStatus } from '../api/queries'

let qc: QueryClient

const config = {
  client_token: 'tok',
  environment: 'sandbox' as const,
  price_ids: {
    starter: { monthly: 'pri_s_m', annual: 'pri_s_a' },
    pro: { monthly: 'pri_p_m', annual: 'pri_p_a' },
  },
  customer_email: 'a@b.test',
  custom_data: { user_id: 1 },
  vaults_cap: 5,
}

beforeEach(() => {
  get.mockReset()
  post.mockReset()
  qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
  qc.setQueryData(['billing', 'config'], config)
})

afterEach(() => {
  qc.clear()
})

function Wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

function billing(overrides: Partial<BillingStatus> = {}): BillingStatus {
  return {
    tier: 'starter',
    active: true,
    trial_days_remaining: 0,
    subscription: { status: 'active', tier: 'starter', current_period_end: '2026-07-01' },
    caps: { obsidian_connections: 1, mcp_connections: 1, api_write_enabled: true },
    ...overrides,
  }
}

describe('PlanChangePanel', () => {
  it('renders Starter + Pro cards using shared PlanCard styling', () => {
    render(<PlanChangePanel billing={billing()} onClose={vi.fn()} onSwitchToCancel={vi.fn()} />, { wrapper: Wrapper })
    expect(screen.getByText('Starter')).toBeInTheDocument()
    expect(screen.getByText('Pro')).toBeInTheDocument()
    expect(screen.getByText('$7/mo')).toBeInTheDocument()
    expect(screen.getByText('$14/mo')).toBeInTheDocument()
  })

  it('marks the user current tier and shows the inert You are on this plan indicator', () => {
    render(<PlanChangePanel billing={billing()} onClose={vi.fn()} onSwitchToCancel={vi.fn()} />, { wrapper: Wrapper })
    // Starter is current → 'Your plan' badge + inert "You're on this plan" status
    expect(screen.getAllByText(/your plan/i).length).toBeGreaterThan(0)
    expect(screen.getByRole('status', { name: /your current plan/i })).toBeInTheDocument()
  })

  it('fetches preview when a target is selected and shows proration', async () => {
    post.mockResolvedValue({
      old_total: 700,
      new_total: 1400,
      immediate_charge_or_credit: 350,
      next_billed_at: '2026-07-01T00:00:00Z',
    })

    render(<PlanChangePanel billing={billing()} onClose={vi.fn()} onSwitchToCancel={vi.fn()} />, { wrapper: Wrapper })
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith('/billing/plan-change/preview', {
        target_price_id: 'pri_p_m',
      }),
    )
    expect(await screen.findByText(/charged \$3\.50 today/i)).toBeInTheDocument()
  })

  it('confirm fires the mutation and onClose on success', async () => {
    post
      .mockResolvedValueOnce({
        old_total: 700,
        new_total: 1400,
        immediate_charge_or_credit: 350,
        next_billed_at: '2026-07-01T00:00:00Z',
      })
      .mockResolvedValueOnce({ transaction_id: 'txn_xyz' })

    const onClose = vi.fn()
    render(<PlanChangePanel billing={billing()} onClose={onClose} onSwitchToCancel={vi.fn()} />, { wrapper: Wrapper })
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    await screen.findByText(/charged \$3\.50 today/i)
    fireEvent.click(screen.getByRole('button', { name: /confirm change/i }))

    await waitFor(() =>
      expect(post).toHaveBeenCalledWith('/billing/plan-change/confirm', {
        target_price_id: 'pri_p_m',
      }),
    )
    await waitFor(() => expect(onClose).toHaveBeenCalled())
  })

  it('preview error: surfaces inline message and keeps Confirm clickable', async () => {
    // Backend bucketed Paddle errors as :paddle_unavailable (503) or
    // :no_active_subscription (422) — both surface as ApiError.throw, query
    // → isError. Without the inline message + open-confirm fix, the user
    // saw "Loading proration…" flash then disappear with a permanently
    // disabled Confirm and no clue why.
    post.mockRejectedValue(new Error('paddle_unavailable'))

    render(<PlanChangePanel billing={billing()} onClose={vi.fn()} onSwitchToCancel={vi.fn()} />, { wrapper: Wrapper })
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))

    expect(await screen.findByText(/could not load proration/i)).toBeInTheDocument()
    const confirmBtn = screen.getByRole('button', { name: /confirm change/i })
    await waitFor(() => expect(confirmBtn).not.toBeDisabled())
  })

  it('proration $0: shows "No charge today" instead of Credited $0.00', async () => {
    post.mockResolvedValue({
      old_total: 700,
      new_total: 700,
      immediate_charge_or_credit: 0,
      next_billed_at: '2026-07-01T00:00:00Z',
    })

    render(<PlanChangePanel billing={billing()} onClose={vi.fn()} onSwitchToCancel={vi.fn()} />, { wrapper: Wrapper })
    fireEvent.click(screen.getByRole('button', { name: /^select$/i }))
    expect(await screen.findByText(/no charge today/i)).toBeInTheDocument()
    expect(screen.queryByText(/credited \$0\.00/i)).not.toBeInTheDocument()
  })

  it('Cancel button closes without firing a mutation', () => {
    const onClose = vi.fn()
    render(<PlanChangePanel billing={billing()} onClose={onClose} onSwitchToCancel={vi.fn()} />, { wrapper: Wrapper })
    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }))
    expect(post).not.toHaveBeenCalled()
    expect(onClose).toHaveBeenCalled()
  })

  it('trial subscription: shows TrialNotice instead of picker; no preview POST', () => {
    // Paddle rejects items-array mutations on a trialing subscription
    // (`subscription_trialing_items_update_invalid_options` for tier swaps,
    // `subscription_new_items_not_valid` for cadence swaps). The picker
    // would 422 on every selection — render the notice instead.
    const trial = billing({
      tier: 'trial',
      trial_days_remaining: 4,
      subscription: { status: 'trialing', tier: 'pro', current_period_end: '2026-06-11' },
    })

    render(<PlanChangePanel billing={trial} onClose={vi.fn()} onSwitchToCancel={vi.fn()} />, { wrapper: Wrapper })

    expect(screen.getByText(/payment processor.*doesn't allow plan changes/i)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /cancel free trial/i })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^select$/i })).not.toBeInTheDocument()
    expect(post).not.toHaveBeenCalled()
  })

  it('trial: "Cancel free trial" button invokes onSwitchToCancel', () => {
    const onSwitchToCancel = vi.fn()
    const trial = billing({
      tier: 'trial',
      subscription: { status: 'trialing', tier: 'pro', current_period_end: '2026-06-11' },
    })

    render(<PlanChangePanel billing={trial} onClose={vi.fn()} onSwitchToCancel={onSwitchToCancel} />, { wrapper: Wrapper })
    fireEvent.click(screen.getByRole('button', { name: /cancel free trial/i }))

    expect(onSwitchToCancel).toHaveBeenCalledOnce()
  })
})

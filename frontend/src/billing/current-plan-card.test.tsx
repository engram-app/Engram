import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import CurrentPlanCard from './current-plan-card'
import type { BillingStatus } from '../api/queries'

function status(overrides: Partial<BillingStatus> = {}): BillingStatus {
  return {
    tier: 'starter',
    active: true,
    trial_days_remaining: 0,
    subscription: { status: 'active', tier: 'starter', current_period_end: '2026-07-01T12:00:00Z' },
    caps: { obsidian_connections: null, mcp_connections: null, api_write_enabled: true },
    current_connections: { obsidian: 0, mcp: 0 },
    ...overrides,
  }
}

describe('CurrentPlanCard', () => {
  it('shows the tier label and active status', () => {
    render(<CurrentPlanCard billing={status()} />)
    expect(screen.getByText('Starter')).toBeInTheDocument()
    expect(screen.getByText(/active/i)).toBeInTheDocument()
  })

  it('labels the period-end date as a renewal when the subscription is active', () => {
    render(<CurrentPlanCard billing={status()} />)
    expect(screen.getByText(/renews on/i)).toBeInTheDocument()
    expect(screen.getByText(/2026/)).toBeInTheDocument()
  })

  it('labels the period-end date as access-ending when canceled', () => {
    render(
      <CurrentPlanCard
        billing={status({
          active: false,
          subscription: { status: 'canceled', tier: 'pro', current_period_end: '2026-07-01T12:00:00Z' },
        })}
      />,
    )
    expect(screen.getByText(/access ends on/i)).toBeInTheDocument()
    expect(screen.queryByText(/renews on/i)).not.toBeInTheDocument()
  })

  it('surfaces remaining trial days while trialing', () => {
    render(
      <CurrentPlanCard
        billing={status({
          tier: 'trial',
          trial_days_remaining: 5,
          subscription: { status: 'trialing', tier: 'starter', current_period_end: '2026-07-01T12:00:00Z' },
        })}
      />,
    )
    expect(screen.getByText(/5 days/i)).toBeInTheDocument()
  })
})

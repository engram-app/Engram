import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'

const { post } = vi.hoisted(() => ({ post: vi.fn() }))
vi.mock('../api/client', () => ({
  api: { get: vi.fn(), post, patch: vi.fn(), del: vi.fn() },
  setTokenGetter: vi.fn(),
}))

import CancelPanel from './cancel-panel'
import type { SubscriptionDetail } from '../api/queries'

let qc: QueryClient

beforeEach(() => {
  post.mockReset()
  qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
})

afterEach(() => {
  qc.clear()
})

function Wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

function detail(overrides: Partial<SubscriptionDetail> = {}): SubscriptionDetail {
  return {
    next_billed_at: '2026-07-01T00:00:00Z',
    amount: '14.00',
    currency: 'USD',
    billing_cycle: { interval: 'month', frequency: 1 },
    scheduled_change: null,
    ...overrides,
  }
}

describe('CancelPanel', () => {
  it('renders the access-end date pulled from next_billed_at', () => {
    render(<CancelPanel detail={detail()} onClose={vi.fn()} />, { wrapper: Wrapper })
    expect(screen.getByText(/keep pro access/i)).toBeInTheDocument()
    expect(screen.getByText(/2026/)).toBeInTheDocument()
  })

  it('confirm calls cancel mutation and onClose on success', async () => {
    post.mockResolvedValue({ scheduled_change: { effective_at: '2026-07-01T00:00:00Z' } })
    const onClose = vi.fn()

    render(<CancelPanel detail={detail()} onClose={onClose} />, { wrapper: Wrapper })
    fireEvent.click(screen.getByRole('button', { name: /cancel at period end/i }))

    await waitFor(() => expect(onClose).toHaveBeenCalled())
    expect(post).toHaveBeenCalledWith('/billing/cancel-subscription')
  })

  it('keep button calls onClose without firing the mutation', () => {
    const onClose = vi.fn()
    render(<CancelPanel detail={detail()} onClose={onClose} />, { wrapper: Wrapper })

    fireEvent.click(screen.getByRole('button', { name: /keep my subscription/i }))

    expect(post).not.toHaveBeenCalled()
    expect(onClose).toHaveBeenCalled()
  })

  it('falls back to generic copy when next_billed_at is null', () => {
    render(<CancelPanel detail={detail({ next_billed_at: null })} onClose={vi.fn()} />, {
      wrapper: Wrapper,
    })
    expect(
      screen.getByText(/keep paid access through the end of your current billing period/i),
    ).toBeInTheDocument()
  })
})

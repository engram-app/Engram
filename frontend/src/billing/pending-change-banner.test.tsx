import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { ReactNode } from 'react'

const { post } = vi.hoisted(() => ({ post: vi.fn() }))
vi.mock('../api/client', () => ({
  api: { get: vi.fn(), post, patch: vi.fn(), del: vi.fn() },
  setTokenGetter: vi.fn(),
}))

import PendingChangeBanner from './pending-change-banner'

let qc: QueryClient

beforeEach(() => {
  post.mockReset()
  qc = new QueryClient({
    defaultOptions: { queries: { retry: false }, mutations: { retry: false } },
  })
})

afterEach(() => {
  qc.clear()
})

function Wrapper({ children }: { children: ReactNode }) {
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

describe('PendingChangeBanner', () => {
  it('announces a scheduled cancellation with its effective date', () => {
    render(
      <PendingChangeBanner
        scheduledChange={{ action: 'cancel', effective_at: '2026-06-27T07:00:00Z' }}
      />,
      { wrapper: Wrapper },
    )
    expect(screen.getByText(/cancels/i)).toBeInTheDocument()
    expect(screen.getByText(/2026/)).toBeInTheDocument()
  })

  it('renders nothing when there is no scheduled change', () => {
    const { container } = render(<PendingChangeBanner scheduledChange={null} />, {
      wrapper: Wrapper,
    })
    expect(container).toBeEmptyDOMElement()
  })

  it('shows a Keep my subscription button on a scheduled cancel that fires reverse-cancel', async () => {
    post.mockResolvedValue({ scheduled_change: null })

    render(
      <PendingChangeBanner
        scheduledChange={{ action: 'cancel', effective_at: '2026-06-27T07:00:00Z' }}
      />,
      { wrapper: Wrapper },
    )
    fireEvent.click(screen.getByRole('button', { name: /keep my subscription/i }))

    await waitFor(() => expect(post).toHaveBeenCalledWith('/billing/reverse-cancel'))
  })

  it('does NOT show the reverse-cancel button for non-cancel scheduled changes (e.g. pause)', () => {
    render(
      <PendingChangeBanner
        scheduledChange={{ action: 'pause', effective_at: '2026-06-27T07:00:00Z' }}
      />,
      { wrapper: Wrapper },
    )
    expect(screen.queryByRole('button', { name: /keep my subscription/i })).not.toBeInTheDocument()
  })
})

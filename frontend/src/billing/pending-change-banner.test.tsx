import { render, screen } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import PendingChangeBanner from './pending-change-banner'

describe('PendingChangeBanner', () => {
  it('announces a scheduled cancellation with its effective date', () => {
    render(
      <PendingChangeBanner
        scheduledChange={{ action: 'cancel', effective_at: '2026-06-27T07:00:00Z' }}
      />,
    )
    expect(screen.getByText(/cancels/i)).toBeInTheDocument()
    expect(screen.getByText(/2026/)).toBeInTheDocument()
  })

  it('renders nothing when there is no scheduled change', () => {
    const { container } = render(<PendingChangeBanner scheduledChange={null} />)
    expect(container).toBeEmptyDOMElement()
  })
})

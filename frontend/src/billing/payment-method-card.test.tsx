import { fireEvent, render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import PaymentMethodCard from './payment-method-card'

describe('PaymentMethodCard', () => {
  it('renders the card brand, last4, and expiry', () => {
    render(
      <PaymentMethodCard
        paymentMethod={{
          type: 'card',
          card_brand: 'visa',
          last4: '4242',
          exp_month: 3,
          exp_year: 2027,
        }}
        onUpdate={() => {}}
      />,
    )
    expect(screen.getByText(/visa/i)).toBeInTheDocument()
    expect(screen.getByText(/4242/)).toBeInTheDocument()
    expect(screen.getByText(/03\/2027/)).toBeInTheDocument()
  })

  it('shows an empty state when no method is on file', () => {
    render(<PaymentMethodCard paymentMethod={null} onUpdate={() => {}} />)
    expect(screen.getByText(/no payment method/i)).toBeInTheDocument()
  })

  it('calls onUpdate when the Update button is clicked', async () => {
    const onUpdate = vi.fn()
    render(<PaymentMethodCard paymentMethod={null} onUpdate={onUpdate} />)
    fireEvent.click(screen.getByRole('button', { name: /update/i }))
    expect(onUpdate).toHaveBeenCalledOnce()
  })
})

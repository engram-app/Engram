import { describe, it, expect, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { ActivationOverlay } from './activation-overlay'

describe('ActivationOverlay', () => {
  it('renders all three step labels', () => {
    render(
      <ActivationOverlay
        state="accelerated"
        subscriptionOk={false}
        nextStep="billing"
        transactionId="txn_1"
        onRefresh={() => {}}
        onContactSupport={() => {}}
      />,
    )
    expect(screen.getByText('Payment received')).toBeInTheDocument()
    expect(screen.getByText('Activating subscription')).toBeInTheDocument()
    expect(screen.getByText('Preparing your account')).toBeInTheDocument()
  })

  it('marks step 1 done, step 2 active, step 3 pending in accelerated state with sub not yet active', () => {
    render(
      <ActivationOverlay
        state="accelerated"
        subscriptionOk={false}
        nextStep="billing"
        transactionId="txn_1"
        onRefresh={() => {}}
        onContactSupport={() => {}}
      />,
    )
    expect(screen.getByTestId('step-1')).toHaveAttribute('data-state', 'done')
    expect(screen.getByTestId('step-2')).toHaveAttribute('data-state', 'active')
    expect(screen.getByTestId('step-3')).toHaveAttribute('data-state', 'pending')
  })

  it('ticks step 2 done when subscriptionOk becomes true (but next_step still billing)', () => {
    render(
      <ActivationOverlay
        state="accelerated"
        subscriptionOk={true}
        nextStep="billing"
        transactionId="txn_1"
        onRefresh={() => {}}
        onContactSupport={() => {}}
      />,
    )
    expect(screen.getByTestId('step-1')).toHaveAttribute('data-state', 'done')
    expect(screen.getByTestId('step-2')).toHaveAttribute('data-state', 'done')
    expect(screen.getByTestId('step-3')).toHaveAttribute('data-state', 'active')
  })

  it('marks all three steps done in activated state', () => {
    render(
      <ActivationOverlay
        state="activated"
        subscriptionOk={true}
        nextStep="tools"
        transactionId="txn_1"
        onRefresh={() => {}}
        onContactSupport={() => {}}
      />,
    )
    expect(screen.getByTestId('step-1')).toHaveAttribute('data-state', 'done')
    expect(screen.getByTestId('step-2')).toHaveAttribute('data-state', 'done')
    expect(screen.getByTestId('step-3')).toHaveAttribute('data-state', 'done')
  })

  it('renders recovery banner with role=alert in cooldown state', () => {
    render(
      <ActivationOverlay
        state="cooldown"
        subscriptionOk={false}
        nextStep="billing"
        transactionId="txn_1"
        onRefresh={() => {}}
        onContactSupport={() => {}}
      />,
    )
    const alert = screen.getByRole('alert')
    expect(alert).toHaveTextContent(/taking a bit longer/i)
    expect(screen.getByRole('button', { name: /refresh/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /contact support/i })).toBeInTheDocument()
  })

  it('calls onRefresh when refresh button is clicked', () => {
    const onRefresh = vi.fn()
    render(
      <ActivationOverlay
        state="cooldown"
        subscriptionOk={false}
        nextStep="billing"
        transactionId="txn_1"
        onRefresh={onRefresh}
        onContactSupport={() => {}}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /refresh/i }))
    expect(onRefresh).toHaveBeenCalledOnce()
  })

  it('calls onContactSupport when contact support is clicked', () => {
    const onContactSupport = vi.fn()
    render(
      <ActivationOverlay
        state="cooldown"
        subscriptionOk={false}
        nextStep="billing"
        transactionId="txn_1"
        onRefresh={() => {}}
        onContactSupport={onContactSupport}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /contact support/i }))
    expect(onContactSupport).toHaveBeenCalledOnce()
  })

  it('uses role=status on the status line for screen readers (non-cooldown)', () => {
    render(
      <ActivationOverlay
        state="accelerated"
        subscriptionOk={false}
        nextStep="billing"
        transactionId="txn_1"
        onRefresh={() => {}}
        onContactSupport={() => {}}
      />,
    )
    expect(screen.getByRole('status')).toBeInTheDocument()
  })

  it('shows transaction id reference in cooldown banner when provided', () => {
    render(
      <ActivationOverlay
        state="cooldown"
        subscriptionOk={false}
        nextStep="billing"
        transactionId="txn_xyz_42"
        onRefresh={() => {}}
        onContactSupport={() => {}}
      />,
    )
    expect(screen.getByText(/txn_xyz_42/)).toBeInTheDocument()
  })
})

import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { TourOfferModal } from './tour-offer-modal'

describe('TourOfferModal', () => {
  it('renders headline + two buttons; click handlers wired', () => {
    const onTake = vi.fn()
    const onSkip = vi.fn()
    render(<TourOfferModal onTake={onTake} onSkip={onSkip} />)

    expect(screen.getByRole('heading', { name: /quick tour/i })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /take.*tour/i }))
    expect(onTake).toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: /skip/i }))
    expect(onSkip).toHaveBeenCalled()
  })
})

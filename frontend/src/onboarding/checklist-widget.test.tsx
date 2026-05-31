import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ChecklistWidget } from './checklist-widget'

vi.mock('./use-onboarding-actions', () => ({
  useOnboardingActions: () => ({
    isLoading: false,
    vaultCount: 1,
    has: (a: string) => a === 'first_vault_created',
    hasTourDecision: true,
    record: vi.fn(),
    recordAsync: vi.fn(),
  }),
}))

describe('ChecklistWidget', () => {
  it('shows checked vault item, unchecked plugin item, collapses to FAB on dismiss', () => {
    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.getByText(/create.*first vault/i)).toBeInTheDocument()
    expect(screen.getByText(/install.*plugin/i)).toBeInTheDocument()

    fireEvent.click(screen.getByLabelText(/dismiss/i))
    expect(screen.queryByText(/create.*first vault/i)).not.toBeInTheDocument()
    expect(screen.getByLabelText(/open onboarding/i)).toBeInTheDocument()
  })
})

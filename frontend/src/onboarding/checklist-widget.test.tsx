import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ChecklistWidget } from './checklist-widget'

let onboardingActionsValue = {
  isLoading: false,
  vaultCount: 1,
  has: (a: string) => a === 'first_vault_created',
  hasTourDecision: true,
  record: vi.fn(),
  recordAsync: vi.fn(),
}

let onboardingStatusValue: any = {
  data: {
    profile: { uses_obsidian: false, tools: ['claude'] },
  },
  isLoading: false,
}

let connectionsValue: any = { data: [], isLoading: false }

vi.mock('./use-onboarding-actions', () => ({
  useOnboardingActions: () => onboardingActionsValue,
}))

vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    useOnboardingStatus: () => onboardingStatusValue,
    useConnections: () => connectionsValue,
  }
})

beforeEach(() => {
  window.localStorage.clear()
  onboardingActionsValue = {
    isLoading: false,
    vaultCount: 1,
    has: (a: string) => a === 'first_vault_created',
    hasTourDecision: true,
    record: vi.fn(),
    recordAsync: vi.fn(),
  }
  onboardingStatusValue = {
    data: { profile: { uses_obsidian: false, tools: ['claude'] } },
    isLoading: false,
  }
  connectionsValue = { data: [], isLoading: false }
})

afterEach(() => {
  window.localStorage.clear()
})

describe('ChecklistWidget — per-tool rows', () => {
  it('renders one row per slug in profile.tools', () => {
    onboardingStatusValue.data.profile.tools = ['claude', 'cursor']
    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.getByText(/connect claude/i)).toBeInTheDocument()
    expect(screen.getByText(/connect cursor/i)).toBeInTheDocument()
  })

  it('per-tool row CTA links to the mapped marketing doc URL', () => {
    onboardingStatusValue.data.profile.tools = ['claude']
    render(<ChecklistWidget onStartTour={() => {}} />)

    const link = screen.getByRole('link', { name: /setup guide/i })
    expect(link).toHaveAttribute('href', 'https://engram.page/docs/integrations/claude-desktop/')
  })

  it('renders the tour row when the user skipped the offer and has not completed it', () => {
    onboardingActionsValue.has = (a: string) =>
      a === 'first_vault_created' || a === 'tour_offered_skipped'
    onboardingStatusValue.data.profile = { uses_obsidian: false, tools: [] }
    const onStart = vi.fn()
    render(<ChecklistWidget onStartTour={onStart} />)

    fireEvent.click(screen.getByRole('button', { name: /^start$/i }))
    expect(onStart).toHaveBeenCalled()
  })

  it('does not render a row for the web_only slug', () => {
    onboardingStatusValue.data.profile.tools = ['claude', 'web_only']
    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.getByText(/connect claude/i)).toBeInTheDocument()
    expect(screen.queryByText(/web.only/i)).toBeNull()
  })
})

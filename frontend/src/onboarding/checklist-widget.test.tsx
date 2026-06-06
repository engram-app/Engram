import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ChecklistWidget } from './checklist-widget'
import { QueryClient, QueryClientProvider, useQueryClient } from '@tanstack/react-query'
import { useSyncExternalStore } from 'react'
import type { ReactNode } from 'react'
import type { Connection, OnboardingAction, OnboardingStatus } from '../api/queries'
import { useOnboardingActions } from './use-onboarding-actions'

let actionsList: OnboardingAction[] = []
let recordAsyncMock = vi.fn()

let onboardingActionsValue: ReturnType<typeof useOnboardingActions> = {
  isLoading: false,
  vaultCount: 1,
  has: (a: OnboardingAction) => actionsList.includes(a),
  hasTourDecision: true,
  record: vi.fn(),
  recordAsync: recordAsyncMock,
}

let onboardingStatusValue: { data: OnboardingStatus | undefined; isLoading: boolean } = {
  data: {
    enabled: true,
    next_step: 'done',
    steps: [],
    actions: actionsList,
    vault_count: 1,
    profile: { uses_obsidian: false, tools: ['claude'] },
  } as OnboardingStatus,
  isLoading: false,
}

let connectionsValue: { data: Connection[]; isLoading: boolean } = { data: [], isLoading: false }

vi.mock('./use-onboarding-actions', () => ({
  useOnboardingActions: () => onboardingActionsValue,
}))

vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    // Subscribe to the real QueryClient so the widget's optimistic
    // setQueryData(['onboarding', 'status'], ...) call triggers a
    // re-render here just like it would in the real app.
    useOnboardingStatus: () => {
      const qc = useQueryClient()
      const data = useSyncExternalStore(
        (cb) => qc.getQueryCache().subscribe(cb),
        () => qc.getQueryData<OnboardingStatus>(['onboarding', 'status']) ?? onboardingStatusValue.data,
        () => onboardingStatusValue.data,
      )
      return { data, isLoading: onboardingStatusValue.isLoading }
    },
    useConnections: () => connectionsValue,
  }
})

let activeQc: QueryClient | null = null

function wrap(ui: ReactNode) {
  activeQc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  // Pre-seed the cache so the first render sees the same data the mock
  // would have returned synchronously (no flash of loading state).
  activeQc.setQueryData(['onboarding', 'status'], onboardingStatusValue.data)
  return <QueryClientProvider client={activeQc}>{ui}</QueryClientProvider>
}

beforeEach(() => {
  actionsList = []
  recordAsyncMock = vi.fn().mockResolvedValue({ status: 'ok' })
  onboardingActionsValue = {
    isLoading: false,
    vaultCount: 1,
    has: (a: OnboardingAction) => actionsList.includes(a),
    hasTourDecision: true,
    record: vi.fn(),
    recordAsync: recordAsyncMock,
  }
  onboardingStatusValue = {
    data: {
      enabled: true,
      next_step: 'done',
      steps: [],
      actions: actionsList,
      vault_count: 1,
      profile: { uses_obsidian: false, tools: ['claude'] },
    } as OnboardingStatus,
    isLoading: false,
  }
  connectionsValue = { data: [], isLoading: false }
})

afterEach(() => {
  // no-op
})

describe('ChecklistWidget — per-tool rows', () => {
  it('renders one row per slug in profile.tools', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude', 'cursor'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.getByText(/connect claude/i)).toBeInTheDocument()
    expect(screen.getByText(/connect cursor/i)).toBeInTheDocument()
  })

  it('per-tool row CTA links to the mapped marketing doc URL', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    const link = screen.getByRole('link', { name: /setup guide/i })
    expect(link).toHaveAttribute('href', 'https://engram.page/docs/integrations/claude-desktop/')
  })

  it('renders the tour row whenever the user has not completed the tour', () => {
    // No tour_offered_skipped required anymore — the row is standing.
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: [] }
    const onStart = vi.fn()
    render(wrap(<ChecklistWidget onStartTour={onStart} />))

    fireEvent.click(screen.getByRole('button', { name: /^start$/i }))
    expect(onStart).toHaveBeenCalled()
  })

  it('does not render a row for the web_only slug', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude', 'web_only'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.getByText(/connect claude/i)).toBeInTheDocument()
    expect(screen.queryByText(/web.only/i)).toBeNull()
  })

  it('falls back to /docs/integrations/ for an unmapped slug', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['some_brand_new_tool'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    const link = screen.getByRole('link', { name: /setup guide/i })
    expect(link).toHaveAttribute('href', 'https://engram.page/docs/integrations/')
  })

  it('per-tool CTA opens in a new tab with rel=noreferrer', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    const link = screen.getByRole('link', { name: /setup guide/i })
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', 'noreferrer')
  })
})

describe('ChecklistWidget — Obsidian plugin row', () => {
  it('renders the Obsidian plugin row when uses_obsidian is true', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: true, tools: [] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.getByText(/install.*obsidian/i)).toBeInTheDocument()

    const link = screen.getByRole('link', { name: /setup guide/i })
    expect(link).toHaveAttribute('href', 'https://engram.page/docs/obsidian/install/')
  })

  it('omits the Obsidian plugin row when uses_obsidian is false', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.queryByText(/install.*obsidian/i)).toBeNull()
  })

  it('hides the Obsidian row when an obsidian connection exists', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: true, tools: [] }
    connectionsValue = {
      data: [
        {
          kind: 'obsidian', client_id: 'obs_1', key_id: null,
          name: 'Engram Vault Sync',
          software_id: null, software_version: null,
          verified: true, logo: null,
          vault_id: null, vault_name: null,
          scope: null, last_used_at: null, connected_at: null,
          first_user_agent: null, first_ip: null,
          redirect_uris: [],
        },
      ],
      isLoading: false,
    }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.queryByText(/install.*obsidian/i)).toBeNull()
  })
})

describe('ChecklistWidget — dismiss', () => {
  it('does not render a row already recorded as dismissed', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude', 'cursor'] }
    actionsList.push('dismissed:claude')

    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.queryByText(/connect claude/i)).toBeNull()
    expect(screen.getByText(/connect cursor/i)).toBeInTheDocument()
  })

  it('clicking dismiss calls recordAsync with dismissed:<slug>', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    fireEvent.click(screen.getByLabelText(/dismiss connect claude/i))

    expect(recordAsyncMock).toHaveBeenCalledWith('dismissed:claude')
  })

  it('optimistically hides the row before the mutation resolves', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude'] }
    recordAsyncMock.mockImplementation(() => new Promise(() => {})) // stays pending
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    fireEvent.click(screen.getByLabelText(/dismiss connect claude/i))

    expect(screen.queryByText(/connect claude/i)).toBeNull()
  })

  it('dismisses the Obsidian row by writing dismissed:install_obsidian_plugin', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: true, tools: [] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    fireEvent.click(screen.getByLabelText(/dismiss install the obsidian plugin/i))

    expect(recordAsyncMock).toHaveBeenCalledWith('dismissed:install_obsidian_plugin')
  })

  it('does not render a dismiss button on the vault row', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: [] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.queryByLabelText(/dismiss create your first vault/i)).toBeNull()
  })

  it('dismissing the tour row records dismissed:tour', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: [] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    fireEvent.click(screen.getByLabelText(/dismiss take the tour/i))

    expect(recordAsyncMock).toHaveBeenCalledWith('dismissed:tour')
  })

  it('hides the tour row when actions contain dismissed:tour', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: [] }
    actionsList.push('dismissed:tour')

    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.queryByText(/take the tour/i)).toBeNull()
  })

  it('hides the tour row when actions contain tour_completed', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: [] }
    actionsList.push('tour_completed')

    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    expect(screen.queryByText(/take the tour/i)).toBeNull()
  })
})

describe('ChecklistWidget — hide when empty', () => {
  it('renders nothing when every row is done or dismissed', () => {
    actionsList.push(
      'first_vault_created',
      'dismissed:claude',
      'dismissed:tour',
    )
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude'] }

    const { container } = render(wrap(<ChecklistWidget onStartTour={() => {}} />))
    expect(container).toBeEmptyDOMElement()
  })
})

describe('ChecklistWidget — chrome', () => {
  it('shows the Finish setup pill when collapsed', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    // Header × → collapse to pill
    fireEvent.click(screen.getByLabelText(/dismiss checklist/i))
    const pill = screen.getByLabelText(/open setup checklist/i)
    expect(pill).toBeInTheDocument()
    expect(pill).toHaveTextContent(/finish setup/i)
  })

  it('renders a progress readout showing completed vs total', () => {
    onboardingStatusValue.data!.profile = { uses_obsidian: false, tools: ['claude', 'cursor'] }
    render(wrap(<ChecklistWidget onStartTour={() => {}} />))

    // vault + tour + claude + cursor = 4 items, none done.
    expect(screen.getByText(/0 of 4 done/i)).toBeInTheDocument()
  })
})

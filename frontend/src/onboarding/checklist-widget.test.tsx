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

  it('falls back to /docs/integrations/ for an unmapped slug', () => {
    onboardingStatusValue.data.profile.tools = ['some_brand_new_tool']
    render(<ChecklistWidget onStartTour={() => {}} />)

    const link = screen.getByRole('link', { name: /setup guide/i })
    expect(link).toHaveAttribute('href', 'https://engram.page/docs/integrations/')
  })

  it('per-tool CTA opens in a new tab with rel=noreferrer', () => {
    onboardingStatusValue.data.profile.tools = ['claude']
    render(<ChecklistWidget onStartTour={() => {}} />)

    const link = screen.getByRole('link', { name: /setup guide/i })
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', 'noreferrer')
  })
})

describe('ChecklistWidget — Obsidian plugin row', () => {
  it('renders the Obsidian plugin row when uses_obsidian is true', () => {
    onboardingStatusValue.data.profile = { uses_obsidian: true, tools: [] }
    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.getByText(/install.*obsidian/i)).toBeInTheDocument()

    const link = screen.getByRole('link', { name: /setup guide/i })
    expect(link).toHaveAttribute('href', 'https://engram.page/docs/obsidian/install/')
  })

  it('omits the Obsidian plugin row when uses_obsidian is false', () => {
    onboardingStatusValue.data.profile = { uses_obsidian: false, tools: ['claude'] }
    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.queryByText(/install.*obsidian/i)).toBeNull()
  })

  it('hides the Obsidian row when an obsidian connection exists', () => {
    onboardingStatusValue.data.profile = { uses_obsidian: true, tools: [] }
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
    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.queryByText(/install.*obsidian/i)).toBeNull()
  })
})

describe('ChecklistWidget — dismiss + persistence', () => {
  it('dismisses a per-tool row and persists it across renders', () => {
    onboardingStatusValue.data.profile = { uses_obsidian: false, tools: ['claude'] }
    const { unmount } = render(<ChecklistWidget onStartTour={() => {}} />)

    fireEvent.click(screen.getByLabelText(/dismiss connect claude/i))
    expect(screen.queryByText(/connect claude/i)).toBeNull()

    const stored = JSON.parse(window.localStorage.getItem('engram:checklist-dismissed:v1') ?? '[]')
    expect(stored).toContain('claude')

    unmount()
    render(<ChecklistWidget onStartTour={() => {}} />)
    expect(screen.queryByText(/connect claude/i)).toBeNull()
  })

  it('dismisses the Obsidian row when no connection exists yet', () => {
    onboardingStatusValue.data.profile = { uses_obsidian: true, tools: [] }
    render(<ChecklistWidget onStartTour={() => {}} />)

    fireEvent.click(screen.getByLabelText(/dismiss install the obsidian plugin/i))
    expect(screen.queryByText(/install.*obsidian/i)).toBeNull()

    const stored = JSON.parse(window.localStorage.getItem('engram:checklist-dismissed:v1') ?? '[]')
    expect(stored).toContain('install_obsidian_plugin')
  })

  it('does not render a dismiss button on the vault row', () => {
    onboardingStatusValue.data.profile = { uses_obsidian: false, tools: [] }
    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.queryByLabelText(/dismiss create your first vault/i)).toBeNull()
  })
})

describe('ChecklistWidget — legacy dismiss-key migration', () => {
  it('merges engram:setup-cards-dismissed:v1 on first mount and removes the old key', () => {
    window.localStorage.setItem(
      'engram:setup-cards-dismissed:v1',
      JSON.stringify(['claude', 'cursor']),
    )
    onboardingStatusValue.data.profile = { uses_obsidian: false, tools: ['claude', 'cursor', 'cline'] }

    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.queryByText(/connect claude/i)).toBeNull()
    expect(screen.queryByText(/connect cursor/i)).toBeNull()
    expect(screen.getByText(/connect cline/i)).toBeInTheDocument()

    const migrated = JSON.parse(
      window.localStorage.getItem('engram:checklist-dismissed:v1') ?? '[]',
    )
    expect(migrated.sort()).toEqual(['claude', 'cursor'])
    expect(window.localStorage.getItem('engram:setup-cards-dismissed:v1')).toBeNull()
  })

  it('is idempotent (re-mount with old key already removed is a no-op)', () => {
    window.localStorage.setItem(
      'engram:checklist-dismissed:v1',
      JSON.stringify(['claude']),
    )
    onboardingStatusValue.data.profile = { uses_obsidian: false, tools: ['claude'] }

    render(<ChecklistWidget onStartTour={() => {}} />)

    expect(screen.queryByText(/connect claude/i)).toBeNull()
    expect(window.localStorage.getItem('engram:setup-cards-dismissed:v1')).toBeNull()
  })
})

describe('ChecklistWidget — hide when empty', () => {
  it('renders nothing when every row is done or dismissed', () => {
    onboardingActionsValue.has = () => true // vault done
    onboardingStatusValue.data.profile = { uses_obsidian: false, tools: ['claude'] }
    window.localStorage.setItem(
      'engram:checklist-dismissed:v1',
      JSON.stringify(['claude']),
    )

    const { container } = render(<ChecklistWidget onStartTour={() => {}} />)
    expect(container).toBeEmptyDOMElement()
  })
})

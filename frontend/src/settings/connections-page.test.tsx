import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router'
import ConnectionsPage from './connections-page'

// ── Controllable mock state ───────────────────────────────────
// vi.mock is hoisted; we use these module-level variables to vary
// the data returned per test without re-importing.

const mockConnections: import('../api/queries').Connection[] = []
let mockTier: string = 'starter'

vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    useConnections: () => ({
      data: mockConnections,
      isLoading: false,
      error: null,
    }),
    useBillingStatus: () => ({ data: { tier: mockTier } }),
    useRevokeOauthConnection: () => ({ mutate: vi.fn() }),
    useRevokeDeviceConnection: () => ({ mutate: vi.fn() }),
    useRevokePat: () => ({ mutate: vi.fn() }),
    useCreatePat: () => ({
      mutate: vi.fn(),
      mutateAsync: vi.fn(),
      isPending: false,
      error: null,
    }),
  }
})

// ── Fixture data ──────────────────────────────────────────────

const baseObs: import('../api/queries').Connection = {
  kind: 'obsidian',
  client_id: 'family-1',
  key_id: null,
  name: 'Obsidian Vault Sync',
  software_id: 'engram-vault-sync',
  software_version: null,
  verified: true,
  logo: '/x.svg',
  vault_id: 1,
  vault_name: null,
  scope: null,
  last_used_at: null,
  connected_at: '2026-05-30T00:00:00Z',
  first_user_agent: null,
  first_ip: null,
  redirect_uris: [],
}

const basePat: import('../api/queries').Connection = {
  kind: 'pat',
  client_id: null,
  key_id: 7,
  name: 'ci-bot',
  software_id: null,
  software_version: null,
  verified: false,
  logo: null,
  vault_id: null,
  vault_name: null,
  scope: null,
  last_used_at: null,
  connected_at: '2026-05-30T00:00:00Z',
  first_user_agent: null,
  first_ip: null,
  redirect_uris: [],
}

const baseMcp: import('../api/queries').Connection = {
  kind: 'mcp',
  client_id: 'client-abc',
  key_id: null,
  name: 'Claude Desktop',
  software_id: 'claude-desktop',
  software_version: '1.2.0',
  verified: false,
  logo: null,
  vault_id: null,
  vault_name: null,
  scope: 'notes:read notes:write',
  last_used_at: null,
  connected_at: '2026-05-30T00:00:00Z',
  first_user_agent: 'Claude/1.2.0',
  first_ip: '1.2.3.4',
  redirect_uris: ['http://localhost:3000/callback'],
}

// ── Render helper ─────────────────────────────────────────────

function renderPage() {
  const qc = new QueryClient()
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <ConnectionsPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

// ── Tests ─────────────────────────────────────────────────────

describe('ConnectionsPage', () => {
  it('renders the three section headings', () => {
    mockConnections.splice(0, mockConnections.length, baseObs, basePat)
    mockTier = 'starter'
    renderPage()
    expect(screen.getByRole('heading', { name: /Obsidian plugins/i })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /AI tools/i })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /API keys/i })).toBeInTheDocument()
  })

  it('shows the obsidian connection name and omits the unverified badge', () => {
    mockConnections.splice(0, mockConnections.length, baseObs, basePat)
    mockTier = 'starter'
    renderPage()
    expect(screen.getByText(/Obsidian Vault Sync/i)).toBeInTheDocument()
    expect(screen.queryByText(/unverified/i)).not.toBeInTheDocument()
  })

  it('shows the PAT in the api-keys section', () => {
    mockConnections.splice(0, mockConnections.length, baseObs, basePat)
    mockTier = 'starter'
    renderPage()
    expect(screen.getByText(/ci-bot/i)).toBeInTheDocument()
  })

  it('shows MCP empty state when no mcp connections', () => {
    mockConnections.splice(0, mockConnections.length, baseObs, basePat)
    mockTier = 'starter'
    renderPage()
    expect(
      screen.getByText(/Connect Claude Desktop, Cursor, or another MCP client/i),
    ).toBeInTheDocument()
  })

  it('shows create button when tier is paid', () => {
    mockConnections.splice(0, mockConnections.length, baseObs, basePat)
    mockTier = 'starter'
    renderPage()
    expect(screen.getByRole('button', { name: /\+ New Key/i })).toBeInTheDocument()
  })

  it('shows upgrade CTA when tier is free', () => {
    mockConnections.splice(0, mockConnections.length, basePat)
    mockTier = 'free'
    renderPage()
    expect(screen.getByText(/Upgrade to Starter to create API keys/i)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /\+ New Key/i })).not.toBeInTheDocument()
  })

  it('shows unverified badge for MCP connection with verified=false', () => {
    mockConnections.splice(0, mockConnections.length, baseMcp)
    mockTier = 'starter'
    renderPage()
    expect(screen.getByText(/unverified/i)).toBeInTheDocument()
    expect(screen.getByText(/Claude Desktop/i)).toBeInTheDocument()
  })
})

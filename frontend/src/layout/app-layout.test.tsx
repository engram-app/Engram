import { render, screen } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import AppLayout from './app-layout'
import { ThemeProvider } from '../theme/theme-provider'
import { ConfigProvider } from '../config-context'
import type { EngramConfig } from '../config'

// AppSidebarPanel reads the billing flag via useIsFreeTier() -> useConfig();
// the layout tree won't mount without a ConfigProvider above it.
const testConfig: EngramConfig = {
  authProvider: 'clerk',
  clerkPublishableKey: '',
  billingEnabled: true,
  clerkWaitlistMode: false,
  apiBase: '',
  wsBase: '',
}

vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    useBillingStatus: () => ({ data: { subscription: { status: 'active' } } }),
    useSearch: () => ({ data: [], isLoading: false, error: null }),
  }
})
vi.mock('../api/use-channel', () => ({ useChannel: () => {} }))
vi.mock('../onboarding/tour/demo-vault-provider', () => ({ useDemoVaultOptional: () => null }))
vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ user: { email: 't@example.com', imageUrl: null }, logout: vi.fn() }),
}))

function renderLayout() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <ConfigProvider config={testConfig}>
    <QueryClientProvider client={qc}>
      <ThemeProvider>
        <MemoryRouter initialEntries={['/']}>
          <Routes>
            <Route path="/" element={<AppLayout />}>
              <Route index element={<div>main-content</div>} />
            </Route>
          </Routes>
        </MemoryRouter>
      </ThemeProvider>
    </QueryClientProvider>
    </ConfigProvider>,
  )
}

describe('AppLayout', () => {
  beforeEach(() => {
    window.matchMedia = vi.fn().mockReturnValue({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() }) as any
  })

  it('does NOT render the old top header', () => {
    renderLayout()
    // AppHeader uniquely rendered <nav aria-label="Main navigation">; the new
    // layout uses <nav aria-label="App navigation"> on the Rail.
    expect(screen.queryByRole('navigation', { name: 'Main navigation' })).toBeNull()
  })

  it('renders the rail navigation', () => {
    renderLayout()
    expect(screen.getByRole('navigation', { name: 'App navigation' })).toBeInTheDocument()
  })

  it('renders the outlet content in the main pane', () => {
    renderLayout()
    expect(screen.getByText('main-content')).toBeInTheDocument()
  })
})

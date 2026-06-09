import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import AppSidebarPanel, { Rail } from './app-sidebar'
import { RailViewProvider } from './rail-view-context'
import { ThemeProvider } from '../theme/theme-provider'
import type { BillingStatus } from '../api/queries'

let billingStatusValue: { data: Partial<BillingStatus> | undefined; isLoading: boolean } = {
  data: { tier: 'free', active: false } as Partial<BillingStatus>,
  isLoading: false,
}

vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ user: { email: 'test@example.com', imageUrl: null }, logout: vi.fn() }),
}))
vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    useSearch: () => ({ data: [], isLoading: false, error: null }),
    useBillingStatus: () => billingStatusValue,
  }
})

function renderSidebar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <ThemeProvider>
        <MemoryRouter>
          <RailViewProvider>
            <Rail />
            <AppSidebarPanel />
          </RailViewProvider>
        </MemoryRouter>
      </ThemeProvider>
    </QueryClientProvider>,
  )
}

describe('AppSidebar', () => {
  beforeEach(() => {
    window.localStorage.clear()
    billingStatusValue = {
      data: { tier: 'free', active: false } as Partial<BillingStatus>,
      isLoading: false,
    }
  })

  it('renders Rail + FilesPanel by default', () => {
    renderSidebar()
    expect(screen.getByRole('navigation', { name: 'App navigation' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Files', level: 2 })).toBeInTheDocument()
  })

  it('switches to SearchPanel when Search icon is clicked', () => {
    renderSidebar()
    fireEvent.click(screen.getByRole('button', { name: 'Search' }))
    expect(screen.getByRole('heading', { name: 'Search', level: 2 })).toBeInTheDocument()
    expect(screen.queryByRole('heading', { name: 'Files', level: 2 })).toBeNull()
  })
})

describe('AppSidebar — Free-tier footer', () => {
  beforeEach(() => window.localStorage.clear())

  it('renders the Free footer with an Upgrade link when tier=free', () => {
    billingStatusValue = {
      data: { tier: 'free', active: false } as Partial<BillingStatus>,
      isLoading: false,
    }
    renderSidebar()

    expect(screen.getByText(/free tier.*1 connection/i)).toBeInTheDocument()
    const link = screen.getByRole('link', { name: /upgrade/i })
    expect(link).toHaveAttribute('href', '/settings/billing')
  })

  it('does not render the footer when tier=pro', () => {
    billingStatusValue = {
      data: { tier: 'pro', active: true } as Partial<BillingStatus>,
      isLoading: false,
    }
    renderSidebar()

    expect(screen.queryByText(/free tier.*1 connection/i)).toBeNull()
    expect(screen.queryByRole('link', { name: /upgrade/i })).toBeNull()
  })

  it('does not render the footer while billing status is loading', () => {
    billingStatusValue = { data: undefined, isLoading: true }
    renderSidebar()

    expect(screen.queryByText(/free tier.*1 connection/i)).toBeNull()
    expect(screen.queryByRole('link', { name: /upgrade/i })).toBeNull()
  })
})

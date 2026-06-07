import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import AppSidebarPanel, { Rail } from './app-sidebar'
import { RailViewProvider } from './rail-view-context'
import { ThemeProvider } from '../theme/theme-provider'

vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ user: { email: 'test@example.com', imageUrl: null }, logout: vi.fn() }),
}))
vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return { ...actual, useSearch: () => ({ data: [], isLoading: false, error: null }) }
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
  beforeEach(() => window.localStorage.clear())

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

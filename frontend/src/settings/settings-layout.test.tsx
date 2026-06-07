import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import SettingsLayout from './settings-layout'
import { ThemeProvider } from '../theme/theme-provider'

vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ user: { email: 'todd@example.com' }, logout: vi.fn() }),
}))
vi.mock('../config', () => ({
  config: { authProvider: 'clerk', clerkPublishableKey: '', billingEnabled: true },
}))

function renderAt(path: string) {
  // SettingsLayout now calls useMe(); give it a query client with retry off so
  // an unmocked /api/me fetch fails fast rather than retrying through the test.
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <ThemeProvider>
        <MemoryRouter initialEntries={[path]}>
          <Routes>
            <Route path="/settings" element={<SettingsLayout />}>
              <Route path="api-keys" element={<p>api keys body</p>} />
            </Route>
          </Routes>
        </MemoryRouter>
      </ThemeProvider>
    </QueryClientProvider>,
  )
}

describe('SettingsLayout', () => {
  it('renders the app rail, the settings nav, and the routed section', () => {
    renderAt('/settings/api-keys')
    // Rail replaced the old AppHeader; assert on its nav landmark + the
    // settings-section nav landmark + the routed body.
    expect(screen.getByRole('navigation', { name: 'App navigation' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Account' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Billing' })).toBeInTheDocument()
    expect(screen.getByText('api keys body')).toBeInTheDocument()
  })
})

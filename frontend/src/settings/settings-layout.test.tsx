import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import SettingsLayout from './settings-layout'

vi.mock('../theme/theme-toggle', () => ({ default: () => null }))
vi.mock('../layout/user-menu', () => ({ default: () => null }))
vi.mock('../config', () => ({
  config: { authProvider: 'clerk', clerkPublishableKey: '', billingEnabled: true },
}))

function renderAt(path: string) {
  // SettingsLayout now calls useMe(); give it a query client with retry off so
  // an unmocked /api/me fetch fails fast rather than retrying through the test.
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/settings" element={<SettingsLayout />}>
            <Route path="api-keys" element={<p>api keys body</p>} />
          </Route>
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('SettingsLayout', () => {
  it('renders the shared header, the settings nav, and the routed section', () => {
    renderAt('/settings/api-keys')
    expect(screen.getByText('Engram')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Account' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Billing' })).toBeInTheDocument()
    expect(screen.getByText('api keys body')).toBeInTheDocument()
  })
})

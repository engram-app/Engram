import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import SettingsLayout from './settings-layout'
import { ThemeProvider } from '../theme/theme-provider'
import { ConfigProvider } from '../config-context'
import type { EngramConfig } from '../config'

vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ user: { email: 'todd@example.com' }, logout: vi.fn() }),
}))

const testConfig: EngramConfig = {
  authProvider: 'clerk',
  clerkPublishableKey: '',
  billingEnabled: true,
  clerkWaitlistMode: false,
  apiBase: '',
  wsBase: '',
}

function renderAt(path: string) {
  // SettingsLayout now calls useMe(); give it a query client with retry off so
  // an unmocked /api/me fetch fails fast rather than retrying through the test.
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <ConfigProvider config={testConfig}>
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
      </QueryClientProvider>
    </ConfigProvider>,
  )
}

describe('SettingsLayout', () => {
  beforeEach(() => {
    window.matchMedia = vi.fn().mockReturnValue({ matches: true, addEventListener: vi.fn(), removeEventListener: vi.fn() }) as any
  })

  it('renders as a dialog with the settings nav + routed section', () => {
    renderAt('/settings/api-keys')
    // SettingsLayout is now a Radix Dialog overlaying whatever underlying
    // app route is showing — the Rail lives on AppLayout (parent route), so
    // assert on the dialog + section nav + routed body.
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Account' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Billing' })).toBeInTheDocument()
    expect(screen.getByText('api keys body')).toBeInTheDocument()
  })
})

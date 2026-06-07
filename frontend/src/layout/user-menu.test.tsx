import { describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import UserMenu from './user-menu'
import { ThemeProvider } from '../theme/theme-provider'

vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ user: { email: 'todd@example.com' }, logout: vi.fn() }),
}))

function renderUserMenu() {
  return render(
    <ThemeProvider>
      <MemoryRouter>
        <UserMenu />
      </MemoryRouter>
    </ThemeProvider>,
  )
}

// Radix DropdownMenu opens on keyDown Enter/Space against its trigger; happy-dom
// doesn't fully model pointer events, so we drive the menu via keyboard.
function openMenu() {
  fireEvent.keyDown(screen.getByRole('button', { name: /user menu/i }), { key: 'Enter' })
}

describe('UserMenu', () => {
  it('renders an avatar trigger from the user email initial', () => {
    renderUserMenu()
    const trigger = screen.getByRole('button', { name: 'User menu' })
    expect(trigger).toBeInTheDocument()
    expect(trigger).toHaveTextContent('T')
  })
})

describe('UserMenu — theme row', () => {
  it('opens the menu and exposes Light / Dark / System rows', () => {
    renderUserMenu()
    openMenu()
    expect(screen.getByRole('menuitemradio', { name: 'Light' })).toBeInTheDocument()
    expect(screen.getByRole('menuitemradio', { name: 'Dark' })).toBeInTheDocument()
    expect(screen.getByRole('menuitemradio', { name: 'System' })).toBeInTheDocument()
  })

  it('selecting a theme updates aria-checked on that row', () => {
    renderUserMenu()
    openMenu()
    fireEvent.click(screen.getByRole('menuitemradio', { name: 'Dark' }))
    openMenu()
    expect(screen.getByRole('menuitemradio', { name: 'Dark' })).toHaveAttribute('aria-checked', 'true')
  })
})

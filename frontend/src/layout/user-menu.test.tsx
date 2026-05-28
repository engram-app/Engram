import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import UserMenu from './user-menu'

vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ user: { email: 'todd@example.com' }, logout: vi.fn() }),
}))

describe('UserMenu', () => {
  it('renders an avatar trigger from the user email initial', () => {
    render(
      <MemoryRouter>
        <UserMenu />
      </MemoryRouter>,
    )
    const trigger = screen.getByRole('button', { name: 'User menu' })
    expect(trigger).toBeInTheDocument()
    expect(trigger).toHaveTextContent('T')
  })
})

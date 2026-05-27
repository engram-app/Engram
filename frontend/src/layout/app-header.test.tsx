import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import AppHeader from './app-header'

vi.mock('../theme/theme-toggle', () => ({ default: () => null }))
vi.mock('./user-menu', () => ({ default: () => null }))

describe('AppHeader', () => {
  it('renders the wordmark and Search + Settings nav, no Billing link', () => {
    render(
      <MemoryRouter>
        <AppHeader />
      </MemoryRouter>,
    )
    expect(screen.getByText('Engram')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Search' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Settings' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Billing' })).toBeNull()
  })
})

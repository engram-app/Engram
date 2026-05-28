import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import AppHeader from './app-header'

vi.mock('../theme/theme-toggle', () => ({ default: () => null }))
vi.mock('./user-menu', () => ({ default: () => null }))

describe('AppHeader', () => {
  it('renders the wordmark and Search nav only — Settings and Billing are not top-bar links', () => {
    render(
      <MemoryRouter>
        <AppHeader />
      </MemoryRouter>,
    )
    expect(screen.getByText('Engram')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Search' })).toBeInTheDocument()
    // Settings moved into the user menu; Billing lives under Settings.
    expect(screen.queryByRole('link', { name: 'Settings' })).toBeNull()
    expect(screen.queryByRole('link', { name: 'Billing' })).toBeNull()
  })
})

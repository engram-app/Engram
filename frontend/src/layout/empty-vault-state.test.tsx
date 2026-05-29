import { render, screen } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { MemoryRouter } from 'react-router'
import { EmptyVaultState } from './empty-vault-state'

describe('EmptyVaultState', () => {
  it('prompts the user to create a vault and links to settings', () => {
    render(
      <MemoryRouter>
        <EmptyVaultState />
      </MemoryRouter>,
    )
    expect(screen.getByText(/no vaults/i)).toBeInTheDocument()
    const link = screen.getByRole('link', { name: /create a vault/i })
    expect(link).toHaveAttribute('href', '/settings/vaults')
  })
})

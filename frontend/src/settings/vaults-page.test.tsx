import { render, screen } from '@testing-library/react'
import { describe, it, expect, vi } from 'vitest'

vi.mock('./vaults/active-vaults-section', () => ({ ActiveVaultsSection: () => <div>active-section</div> }))
vi.mock('./vaults/deleted-vaults-section', () => ({ DeletedVaultsSection: () => <div>deleted-section</div> }))

import VaultsPage from './vaults-page'

describe('VaultsPage', () => {
  it('renders header + both sections (create flow lives inside ActiveVaultsSection)', () => {
    render(<VaultsPage />)
    expect(screen.getByRole('heading', { name: /vaults/i })).toBeInTheDocument()
    expect(screen.getByText('active-section')).toBeInTheDocument()
    expect(screen.getByText('deleted-section')).toBeInTheDocument()
  })
})

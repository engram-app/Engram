import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import AuthShell from './auth-shell'

vi.mock('../theme/theme-toggle', () => ({
  default: () => <button type="button">theme</button>,
}))

describe('AuthShell', () => {
  it('renders the Engram wordmark, theme toggle, and children', () => {
    render(
      <AuthShell>
        <p>panel body</p>
      </AuthShell>,
    )
    expect(screen.getByText('Engram')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /theme/i })).toBeInTheDocument()
    expect(screen.getByText('panel body')).toBeInTheDocument()
  })

  it('renders the actions slot when provided', () => {
    render(
      <AuthShell actions={<span>Step 1 of 2</span>}>
        <p>body</p>
      </AuthShell>,
    )
    expect(screen.getByText(/step 1 of 2/i)).toBeInTheDocument()
  })
})

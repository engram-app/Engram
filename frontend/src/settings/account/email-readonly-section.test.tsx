import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

const meData = { id: 1, email: 'me@example.com', role: 'member', display_name: null }
vi.mock('../../api/queries', () => ({ useMe: () => ({ data: meData }) }))

import { EmailReadonlySection } from './email-readonly-section'

describe('EmailReadonlySection', () => {
  it('renders the user email', () => {
    render(<EmailReadonlySection />)
    expect(screen.getByText('me@example.com')).toBeInTheDocument()
  })

  it('mentions contacting an admin', () => {
    render(<EmailReadonlySection />)
    expect(screen.getByText(/contact your admin/i)).toBeInTheDocument()
  })

  it('copy button writes to clipboard', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined)
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText },
      writable: true,
      configurable: true,
    })

    render(<EmailReadonlySection />)
    fireEvent.click(screen.getByRole('button', { name: /copy email/i }))

    expect(writeText).toHaveBeenCalledWith('me@example.com')
  })
})

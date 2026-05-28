import { render, screen, fireEvent } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

const setTheme = vi.fn()
let theme = 'system'
vi.mock('@/theme/theme-provider', () => ({
  useTheme: () => ({ theme, resolved: 'dark', setTheme }),
}))

import { AppearanceSection } from './appearance-section'

describe('AppearanceSection', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    theme = 'system'
  })

  it('marks the active theme as pressed', () => {
    render(<AppearanceSection />)
    expect(screen.getByRole('button', { name: /system/i })).toHaveAttribute('aria-pressed', 'true')
    expect(screen.getByRole('button', { name: /dark/i })).toHaveAttribute('aria-pressed', 'false')
  })

  it('calls setTheme when a choice is clicked', () => {
    render(<AppearanceSection />)
    fireEvent.click(screen.getByRole('button', { name: /dark/i }))
    expect(setTheme).toHaveBeenCalledWith('dark')
  })
})

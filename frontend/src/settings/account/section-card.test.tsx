import { render, screen } from '@testing-library/react'
import { describe, it, expect } from 'vitest'
import { SettingsSectionCard } from './section-card'

describe('SettingsSectionCard', () => {
  it('renders title, description, and children', () => {
    render(
      <SettingsSectionCard title="Profile" description="Your name and avatar">
        <p>body content</p>
      </SettingsSectionCard>,
    )
    expect(screen.getByRole('heading', { name: 'Profile' })).toBeInTheDocument()
    expect(screen.getByText('Your name and avatar')).toBeInTheDocument()
    expect(screen.getByText('body content')).toBeInTheDocument()
  })

  it('omits the description node when not provided', () => {
    render(<SettingsSectionCard title="Sessions"><span>x</span></SettingsSectionCard>)
    expect(screen.getByRole('heading', { name: 'Sessions' })).toBeInTheDocument()
  })
})

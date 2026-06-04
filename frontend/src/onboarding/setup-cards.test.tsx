import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { SetupCards } from './setup-cards'

const PROFILE_BASE = {
  uses_obsidian: false,
  tools: ['claude'],
  completed_at: 'now',
}

beforeEach(() => {
  window.localStorage.clear()
})

afterEach(() => {
  window.localStorage.clear()
})

describe('SetupCards', () => {
  it('renders the Claude Desktop card for a user who picked claude', () => {
    render(<SetupCards profile={PROFILE_BASE} />)
    expect(screen.getByRole('heading', { name: /connect claude desktop/i })).toBeInTheDocument()
  })

  it('prepends the install-Obsidian-plugin card when uses_obsidian=true', () => {
    render(<SetupCards profile={{ ...PROFILE_BASE, uses_obsidian: true }} />)
    expect(
      screen.getByRole('heading', { name: /install the engram obsidian plugin/i }),
    ).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /connect claude desktop/i })).toBeInTheDocument()
  })

  it('renders a coming-soon stub for tools without real instructions yet', () => {
    render(<SetupCards profile={{ ...PROFILE_BASE, tools: ['cline'] }} />)
    expect(
      screen.getByRole('heading', { name: /configure cline/i }),
    ).toBeInTheDocument()
  })

  it('renders coming-soon stubs for the newly-added AI assistant slugs', () => {
    render(
      <SetupCards
        profile={{ ...PROFILE_BASE, tools: ['mistral', 'open_webui', 'opencode'] }}
      />,
    )
    expect(
      screen.getByRole('heading', { name: /connect mistral/i }),
    ).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /connect open webui/i })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: /add engram to opencode/i })).toBeInTheDocument()
  })

  it('dismisses a card on Done click and persists across renders', () => {
    const { unmount } = render(<SetupCards profile={PROFILE_BASE} />)
    fireEvent.click(
      screen.getByRole('button', { name: /dismiss connect claude desktop/i }),
    )
    expect(screen.queryByRole('heading', { name: /connect claude desktop/i })).toBeNull()
    unmount()

    render(<SetupCards profile={PROFILE_BASE} />)
    expect(screen.queryByRole('heading', { name: /connect claude desktop/i })).toBeNull()
  })

  it('renders nothing when every card has been dismissed', () => {
    window.localStorage.setItem(
      'engram:setup-cards-dismissed:v1',
      JSON.stringify(['claude']),
    )
    const { container } = render(<SetupCards profile={PROFILE_BASE} />)
    expect(container.firstChild).toBeNull()
  })

  it('collapses + expands via Hide / Show toggle', () => {
    render(<SetupCards profile={PROFILE_BASE} />)
    fireEvent.click(screen.getByRole('button', { name: /hide/i }))
    expect(screen.queryByRole('heading', { name: /connect claude desktop/i })).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: /show/i }))
    expect(screen.getByRole('heading', { name: /connect claude desktop/i })).toBeInTheDocument()
  })
})

import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'

import NoteView from './note-view'

let mockTier: 'free' | 'starter' | 'pro' | 'trial' | 'none' = 'free'
const showUpgradeMock = vi.fn()

vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    useBillingStatus: () => ({ data: { tier: mockTier } }),
  }
})

vi.mock('@/billing/upgrade-dialog-provider', () => ({
  useUpgradeDialog: () => ({ showUpgrade: showUpgradeMock }),
}))

// AttachmentImg fires a network request via api.getBlob; stub so the
// integration assertion only inspects which branch was taken.
vi.mock('./attachment-img', () => ({
  default: ({ path }: { path: string }) => (
    <span data-testid="attachment-img">{path}</span>
  ),
}))

vi.mock('./mermaid-block', () => ({
  default: () => null,
}))

function renderNote(content: string) {
  return render(
    <NoteView
      content={content}
      title="Test"
      tags={[]}
      updatedAt={new Date('2026-06-07').toISOString()}
    />,
  )
}

describe('NoteView attachment gating', () => {
  it('renders fallback lock for Free user on non-text embeds', () => {
    mockTier = 'free'
    renderNote('Here is an embed:\n\n![[image.png]]\n')
    expect(screen.getByTestId('attachment-fallback-lock')).toBeInTheDocument()
    expect(screen.queryByTestId('attachment-img')).toBeNull()
  })

  it('renders AttachmentImg for paid tier on the same embed', () => {
    mockTier = 'pro'
    renderNote('Here is an embed:\n\n![[image.png]]\n')
    expect(screen.getByTestId('attachment-img')).toHaveTextContent('image.png')
    expect(screen.queryByTestId('attachment-fallback-lock')).toBeNull()
  })

  it('renders AttachmentImg even on Free for .md embeds (text)', () => {
    mockTier = 'free'
    renderNote('Linked note:\n\n![[other.md]]\n')
    expect(screen.getByTestId('attachment-img')).toHaveTextContent('other.md')
    expect(screen.queryByTestId('attachment-fallback-lock')).toBeNull()
  })

  it('renders AttachmentImg on Free for .canvas embeds (text)', () => {
    mockTier = 'free'
    renderNote('Embedded canvas:\n\n![[board.canvas]]\n')
    expect(screen.getByTestId('attachment-img')).toHaveTextContent('board.canvas')
    expect(screen.queryByTestId('attachment-fallback-lock')).toBeNull()
  })
})

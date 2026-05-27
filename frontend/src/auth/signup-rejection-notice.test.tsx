import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import SignupRejectionNotice from './signup-rejection-notice'

const KEY = 'engram:pending-signup'

function setPending(id: string, ts = Date.now()) {
  sessionStorage.setItem(KEY, JSON.stringify({ id, ts }))
}

describe('SignupRejectionNotice', () => {
  beforeEach(() => {
    sessionStorage.clear()
    vi.restoreAllMocks()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('shows the duplicate-account message when the backend reports a rejection', async () => {
    setPending('user_dup')
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ reason: 'duplicate_identity' }), { status: 200 }),
    )

    render(<SignupRejectionNotice />)

    expect(await screen.findByRole('alert')).toHaveTextContent(/already exists/i)
  })

  it('renders nothing when there is no pending sign-up', async () => {
    const fetchSpy = vi.spyOn(globalThis, 'fetch')
    const { container } = render(<SignupRejectionNotice />)

    await waitFor(() => expect(fetchSpy).not.toHaveBeenCalled())
    expect(container).toBeEmptyDOMElement()
  })

  it('renders nothing when the backend has no rejection recorded (404)', async () => {
    setPending('user_clean')
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ reason: null }), { status: 404 }),
    )

    const { container } = render(<SignupRejectionNotice />)

    await waitFor(() => expect(screen.queryByRole('alert')).toBeNull())
    expect(container).toBeEmptyDOMElement()
  })

  it('clears the pending entry so it does not fire twice', async () => {
    setPending('user_dup')
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ reason: 'duplicate_identity' }), { status: 200 }),
    )

    render(<SignupRejectionNotice />)
    await screen.findByRole('alert')

    expect(sessionStorage.getItem(KEY)).toBeNull()
  })
})

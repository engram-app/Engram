import { afterEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import ErrorFallback from './error-fallback'

afterEach(() => {
  vi.unstubAllEnvs()
  vi.restoreAllMocks()
})

describe('ErrorFallback', () => {
  it('renders the branded heading, reload action, and a plain home link', () => {
    render(<ErrorFallback error={new Error('boom')} />)

    expect(
      screen.getByRole('heading', { name: /something went wrong/i }),
    ).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /reload/i })).toBeInTheDocument()
    // Plain anchor (not a router <Link>) — the fallback renders outside
    // RouterProvider, so it must navigate via href, not router context.
    expect(screen.getByRole('link', { name: /back to home/i })).toHaveAttribute(
      'href',
      '/',
    )
  })

  it('shows the Sentry reference id when one is provided', () => {
    render(<ErrorFallback error={new Error('boom')} eventId="abc123" />)
    expect(screen.getByText(/abc123/)).toBeInTheDocument()
  })

  it('omits the reference line when no eventId is present', () => {
    render(<ErrorFallback error={new Error('boom')} />)
    expect(screen.queryByText(/reference/i)).not.toBeInTheDocument()
  })

  it('reveals the error message in dev builds', () => {
    vi.stubEnv('DEV', true)
    render(<ErrorFallback error={new Error('kaboom-detail')} />)
    expect(screen.getByText(/kaboom-detail/)).toBeInTheDocument()
  })

  it('hides the error message in production builds', () => {
    vi.stubEnv('DEV', false)
    render(<ErrorFallback error={new Error('kaboom-detail')} />)
    expect(screen.queryByText(/kaboom-detail/)).not.toBeInTheDocument()
  })

  it('reloads the page when reload is clicked', () => {
    const reload = vi.fn()
    vi.spyOn(window.location, 'reload').mockImplementation(reload)

    render(<ErrorFallback error={new Error('boom')} />)
    fireEvent.click(screen.getByRole('button', { name: /reload/i }))

    expect(reload).toHaveBeenCalledOnce()
  })
})

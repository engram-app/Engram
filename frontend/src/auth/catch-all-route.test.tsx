import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes, useLocation } from 'react-router'
import CatchAllRoute from './catch-all-route'

// Mutable auth state so each test can pick signed-in / signed-out / loading.
const authState = { current: { isLoaded: true, isSignedIn: false } }
vi.mock('./use-auth-adapter', () => ({
  useAuthAdapter: () => authState.current,
}))

vi.mock('../theme/theme-toggle', () => ({
  default: () => <button type="button">theme</button>,
}))

function SignInStub() {
  const { search } = useLocation()
  return <p>sign-in {search}</p>
}

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/sign-in" element={<SignInStub />} />
        <Route path="*" element={<CatchAllRoute />} />
      </Routes>
    </MemoryRouter>,
  )
}

describe('CatchAllRoute', () => {
  it('redirects a signed-out user to sign-in with the attempted path as return_to', () => {
    authState.current = { isLoaded: true, isSignedIn: false }
    renderAt('/some/typo')
    expect(screen.getByText(/sign-in/)).toHaveTextContent('return_to=%2Fsome%2Ftypo')
    expect(screen.queryByText('404')).not.toBeInTheDocument()
  })

  it('shows the 404 page to a signed-in user', () => {
    authState.current = { isLoaded: true, isSignedIn: true }
    renderAt('/some/typo')
    expect(screen.getByText('404')).toBeInTheDocument()
    expect(screen.queryByText(/sign-in/)).not.toBeInTheDocument()
  })

  it('does not redirect or 404 while auth state is still loading', () => {
    authState.current = { isLoaded: false, isSignedIn: false }
    renderAt('/some/typo')
    expect(screen.queryByText('404')).not.toBeInTheDocument()
    expect(screen.queryByText(/sign-in/)).not.toBeInTheDocument()
  })
})

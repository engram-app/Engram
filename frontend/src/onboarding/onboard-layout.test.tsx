import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router'
import OnboardLayout from './onboard-layout'

const logout = vi.fn()

vi.mock('../auth/use-auth-adapter', () => ({
  useAuthAdapter: () => ({ logout }),
}))

vi.mock('../theme/theme-toggle', () => ({
  default: () => null,
}))

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route element={<OnboardLayout />}>
          <Route path="/onboard/agreement" element={<p>agreement step</p>} />
          <Route path="/onboard/billing" element={<p>billing step</p>} />
          <Route path="/onboard/profile" element={<p>profile step</p>} />
          <Route path="/onboard/vault" element={<p>vault step</p>} />
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

describe('OnboardLayout', () => {
  it('numbers each step 1-of-4 through 4-of-4 based on pathname', () => {
    renderAt('/onboard/agreement')
    expect(screen.getByText(/step 1 of 4/i)).toBeInTheDocument()
  })

  it('shows step 2 of 4 on billing', () => {
    renderAt('/onboard/billing')
    expect(screen.getByText(/step 2 of 4/i)).toBeInTheDocument()
    expect(screen.getByText('billing step')).toBeInTheDocument()
  })

  it('shows step 3 of 4 on profile', () => {
    renderAt('/onboard/profile')
    expect(screen.getByText(/step 3 of 4/i)).toBeInTheDocument()
  })

  it('shows step 4 of 4 on vault', () => {
    renderAt('/onboard/vault')
    expect(screen.getByText(/step 4 of 4/i)).toBeInTheDocument()
  })

  it('signs the user out mid-flow', () => {
    renderAt('/onboard/agreement')
    fireEvent.click(screen.getByRole('button', { name: /sign out/i }))
    expect(logout).toHaveBeenCalled()
  })
})

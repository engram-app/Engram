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
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

describe('OnboardLayout', () => {
  it('shows the Engram wordmark and the current step', () => {
    renderAt('/onboard/billing')
    expect(screen.getByText('Engram')).toBeInTheDocument()
    expect(screen.getByText(/step 2 of 2/i)).toBeInTheDocument()
    expect(screen.getByText('billing step')).toBeInTheDocument()
  })

  it('signs the user out mid-flow', () => {
    renderAt('/onboard/agreement')
    fireEvent.click(screen.getByRole('button', { name: /sign out/i }))
    expect(logout).toHaveBeenCalled()
  })
})

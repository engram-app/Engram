import { afterEach, describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import LocalSignUp from './local-sign-up'

const { register } = vi.hoisted(() => ({ register: vi.fn().mockResolvedValue(undefined) }))
vi.mock('./use-auth-adapter', () => ({
  useAuthAdapter: () => ({ register, isSignedIn: false }),
}))

function renderPage() {
  return render(
    <MemoryRouter>
      <LocalSignUp />
    </MemoryRouter>,
  )
}

afterEach(() => vi.clearAllMocks())

describe('LocalSignUp', () => {
  it('blocks submission when passwords do not match', () => {
    renderPage()
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: 'a@b.com' } })
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'secret123' } })
    fireEvent.change(screen.getByLabelText('Confirm password'), { target: { value: 'different1' } })
    fireEvent.click(screen.getByRole('button', { name: /create account/i }))
    expect(screen.getByRole('alert')).toHaveTextContent(/do not match/i)
    expect(register).not.toHaveBeenCalled()
  })

  it('registers when passwords match', async () => {
    renderPage()
    fireEvent.change(screen.getByLabelText('Email'), { target: { value: 'a@b.com' } })
    fireEvent.change(screen.getByLabelText('Password'), { target: { value: 'secret123' } })
    fireEvent.change(screen.getByLabelText('Confirm password'), { target: { value: 'secret123' } })
    fireEvent.click(screen.getByRole('button', { name: /create account/i }))
    await waitFor(() => expect(register).toHaveBeenCalledWith('a@b.com', 'secret123', undefined))
  })
})

import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { makeUser } from './section-test-helpers'

const newEmail = {
  id: 'eml_2',
  emailAddress: 'new@example.com',
  prepareVerification: vi.fn().mockResolvedValue({}),
  attemptVerification: vi.fn().mockResolvedValue({}),
}
const user = makeUser({ createEmailAddress: vi.fn().mockResolvedValue(newEmail) })

vi.mock('@clerk/clerk-react', () => ({
  useUser: () => ({ user, isLoaded: true }),
  useReverification: (fn: unknown) => fn,
}))
vi.mock('@clerk/clerk-react/errors', () => ({ isClerkAPIResponseError: () => false }))
vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { EmailSection } from './email-section'

describe('EmailSection', () => {
  beforeEach(() => vi.clearAllMocks())

  it('lists existing emails', () => {
    render(<EmailSection />)
    expect(screen.getByText('ada@example.com')).toBeInTheDocument()
  })

  it('adds an email and prepares verification', async () => {
    render(<EmailSection />)
    fireEvent.change(screen.getByLabelText(/add email/i), { target: { value: 'new@example.com' } })
    fireEvent.click(screen.getByRole('button', { name: /^add$/i }))
    await waitFor(() => expect(user.createEmailAddress).toHaveBeenCalledWith({ email: 'new@example.com' }))
    await waitFor(() => expect(newEmail.prepareVerification).toHaveBeenCalledWith({ strategy: 'email_code' }))
  })

  it('verifies the new email with a code', async () => {
    render(<EmailSection />)
    fireEvent.change(screen.getByLabelText(/add email/i), { target: { value: 'new@example.com' } })
    fireEvent.click(screen.getByRole('button', { name: /^add$/i }))
    await screen.findByLabelText(/verification code/i)
    fireEvent.change(screen.getByLabelText(/verification code/i), { target: { value: '123456' } })
    fireEvent.click(screen.getByRole('button', { name: /verify/i }))
    await waitFor(() => expect(newEmail.attemptVerification).toHaveBeenCalledWith({ code: '123456' }))
  })

  it('removes an email via destroy', async () => {
    render(<EmailSection />)
    fireEvent.click(screen.getByRole('button', { name: /remove ada@example.com/i }))
    await waitFor(() => expect(user.emailAddresses[0]!.destroy).toHaveBeenCalled())
  })
})

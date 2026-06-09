import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { describe, it, expect, vi, beforeEach } from 'vitest'

// vi.mock factories run at the top of the file — declare their fakes
// via vi.hoisted so the references resolve when the mock executes.
const { mutate, toastError, toastSuccess } = vi.hoisted(() => ({
  mutate: vi.fn(),
  toastError: vi.fn(),
  toastSuccess: vi.fn(),
}))

vi.mock('@/api/queries', () => ({
  useCreateVault: () => ({ mutate, isPending: false }),
}))

vi.mock('sonner', () => ({ toast: { error: toastError, success: toastSuccess } }))

import { VaultCreateForm } from './vault-create-form'

describe('VaultCreateForm onError', () => {
  beforeEach(() => vi.clearAllMocks())

  function submitWithError(err: Error) {
    mutate.mockImplementation((_attrs, opts) => opts?.onError?.(err))
    render(<VaultCreateForm />)
    fireEvent.change(screen.getByLabelText(/vault name/i), { target: { value: 'A' } })
    fireEvent.click(screen.getByRole('button', { name: /create/i }))
  }

  it('shows a toast on a generic failure', async () => {
    submitWithError(new Error('boom'))
    await waitFor(() => expect(toastError).toHaveBeenCalledWith('Could not create vault'))
  })

  it('stays silent on LimitExceededError — UpgradeDialog owns that surface', async () => {
    const limitErr = Object.assign(new Error('limit reached'), { name: 'LimitExceededError' })
    submitWithError(limitErr)
    // Give the mutation callback a tick — toast must NOT fire.
    await new Promise((r) => setTimeout(r, 10))
    expect(toastError).not.toHaveBeenCalled()
  })
})

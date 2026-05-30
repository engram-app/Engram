import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const updateMutate = vi.fn().mockResolvedValue({ user: { display_name: 'Sam' } })
const meData = { id: 1, email: 'me@example.com', role: 'member', display_name: 'Old' }

vi.mock('../../api/queries', () => ({
  useMe: () => ({ data: meData }),
  useUpdateProfile: () => ({ mutateAsync: updateMutate, isPending: false }),
}))

import { ProfileSectionLocal } from './profile-section-local'

function wrap(ui: React.ReactNode) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(<QueryClientProvider client={qc}>{ui}</QueryClientProvider>)
}

describe('ProfileSectionLocal', () => {
  it('shows current display_name and submits new value', async () => {
    wrap(<ProfileSectionLocal />)
    const input = screen.getByLabelText(/display name/i) as HTMLInputElement
    expect(input.value).toBe('Old')

    fireEvent.change(input, { target: { value: 'Sam' } })
    fireEvent.click(screen.getByRole('button', { name: /save/i }))

    await waitFor(() =>
      expect(updateMutate).toHaveBeenCalledWith({ display_name: 'Sam' }),
    )
  })
})

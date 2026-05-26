import { describe, expect, it, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import AgreementPage from './agreement-page'

const mutate = vi.fn().mockResolvedValue({ version: '2026-05-15', accepted_at: 'now' })

vi.mock('../api/queries', () => ({
  useAcceptTerms: () => ({ mutateAsync: mutate, isPending: false }),
  useOnboardingStatus: () => ({
    data: { enabled: true, next_step: 'agreement', current_tos_version: '2026-05-15' },
    isLoading: false,
  }),
}))

function renderPage() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <AgreementPage />
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('AgreementPage', () => {
  it('disables Continue until the agreement checkbox is checked', () => {
    renderPage()
    const button = screen.getByRole('button', { name: /continue/i })
    expect(button).toBeDisabled()

    fireEvent.click(screen.getByRole('checkbox', { name: /agree/i }))
    expect(button).not.toBeDisabled()
  })

  it('calls accept-terms with the current version on submit', async () => {
    renderPage()
    fireEvent.click(screen.getByRole('checkbox', { name: /agree/i }))
    fireEvent.click(screen.getByRole('button', { name: /continue/i }))

    await waitFor(() => expect(mutate).toHaveBeenCalledWith('2026-05-15'))
  })

  it('links out to the hosted Terms and Privacy pages in a new tab', () => {
    renderPage()
    const terms = screen.getByRole('link', { name: /terms of service/i })
    const privacy = screen.getByRole('link', { name: /privacy policy/i })
    expect(terms).toHaveAttribute('href', 'https://engram.page/terms')
    expect(privacy).toHaveAttribute('href', 'https://engram.page/privacy')
    expect(terms).toHaveAttribute('target', '_blank')
    expect(terms).toHaveAttribute('rel', expect.stringContaining('noopener'))
  })
})

import { render, screen, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { MemoryRouter, Routes, Route, useNavigate } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { LegacyNoteResolver } from './legacy-note-resolver'
import { useNoteByPath } from '../api/queries'

vi.mock('react-router', async () => {
  const actual = await vi.importActual<typeof import('react-router')>('react-router')
  return { ...actual, useNavigate: vi.fn(actual.useNavigate) }
})

vi.mock('../api/queries', () => ({
  useNoteByPath: vi.fn(),
}))

function wrapper(qc: QueryClient, initialPath: string) {
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>
      <MemoryRouter initialEntries={[initialPath]}>
        <Routes>
          <Route path="/note/*" element={children} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe('LegacyNoteResolver', () => {
  it('navigates to /note/:id with replace once the path resolves', async () => {
    const navigate = vi.fn()
    vi.mocked(useNavigate).mockReturnValue(navigate)
    vi.mocked(useNoteByPath).mockReturnValue({
      data: { id: 42, path: 'a.md' } as never,
      isLoading: false,
      isError: false,
    } as never)

    const qc = new QueryClient()
    render(<LegacyNoteResolver />, { wrapper: wrapper(qc, '/note/a.md') })

    await waitFor(() => expect(navigate).toHaveBeenCalledWith('/note/42', { replace: true }))
  })

  it('renders not-found state on error', () => {
    vi.mocked(useNavigate).mockReturnValue(vi.fn())
    vi.mocked(useNoteByPath).mockReturnValue({
      data: undefined,
      isLoading: false,
      isError: true,
    } as never)

    const qc = new QueryClient()
    render(<LegacyNoteResolver />, { wrapper: wrapper(qc, '/note/missing.md') })

    expect(screen.getByText(/not found/i)).toBeInTheDocument()
  })

  it('shows loading state', () => {
    vi.mocked(useNavigate).mockReturnValue(vi.fn())
    vi.mocked(useNoteByPath).mockReturnValue({
      data: undefined,
      isLoading: true,
      isError: false,
    } as never)

    const qc = new QueryClient()
    render(<LegacyNoteResolver />, { wrapper: wrapper(qc, '/note/a.md') })

    expect(screen.getByText(/loading/i)).toBeInTheDocument()
  })
})

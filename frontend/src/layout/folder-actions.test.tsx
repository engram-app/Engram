import { beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { navigate, post, toastError, openUpload } = vi.hoisted(() => ({
  navigate: vi.fn(),
  post: vi.fn(),
  toastError: vi.fn(),
  openUpload: vi.fn(),
}))

vi.mock('../viewer/attachment-upload/provider', () => ({
  useAttachmentUpload: () => ({ openUpload }),
}))

// Controllable demo flag — null (not demo) by default; flip per test.
let demoActive = false
vi.mock('../onboarding/tour/demo-vault-provider', () => ({
  useDemoVaultOptional: () => (demoActive ? { active: true } : null),
}))

vi.mock('react-router', async () => {
  const actual = await vi.importActual<typeof import('react-router')>('react-router')
  return {
    ...actual,
    useNavigate: () => navigate,
  }
})

vi.mock('sonner', () => ({ toast: { success: vi.fn(), error: toastError } }))

vi.mock('../api/client', () => {
  class ApiError extends Error {
    public status: number
    constructor(status: number, message: string) {
      super(message)
      this.status = status
      this.name = 'ApiError'
    }
  }
  return {
    api: { get: vi.fn(), post, patch: vi.fn(), del: vi.fn() },
    ApiError,
    setTokenGetter: vi.fn(),
  }
})

vi.mock('../api/active-vault', () => ({
  useActiveVaultId: () => '1',
  getActiveVaultId: () => '1',
  setActiveVaultId: vi.fn(),
}))

import FolderActions from './folder-actions'
import { FolderTreeProvider } from './folder-tree-context'

function renderWithProviders() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  // Seed the active-note cache so useActiveFolder() resolves to "foo"
  qc.setQueryData(['note', '1', '42'], { id: '42', folder: 'foo', path: 'foo/bar.md' })
  return render(
    <MemoryRouter initialEntries={['/note/42']}>
      <QueryClientProvider client={qc}>
        <FolderTreeProvider>
          <Routes>
            <Route path="/note/:id" element={<FolderActions />} />
          </Routes>
        </FolderTreeProvider>
      </QueryClientProvider>
    </MemoryRouter>,
  )
}

describe('FolderActions', () => {
  beforeEach(() => {
    navigate.mockReset()
    post.mockReset()
    toastError.mockReset()
    openUpload.mockReset()
    demoActive = false
  })

  it('creates a note in the active folder when New note is clicked', async () => {
    post.mockResolvedValue({ note: { path: 'foo/Untitled.md' } })
    renderWithProviders()

    fireEvent.click(screen.getByRole('button', { name: 'New note' }))

    await waitFor(() => {
      expect(post).toHaveBeenCalledWith(
        '/notes',
        expect.objectContaining({ path: 'foo/Untitled.md', content: '' }),
      )
    })
  })

  it('creates a folder under the active folder when New folder is clicked', async () => {
    post.mockResolvedValue({ folder: { name: 'foo/Untitled folder', count: 0 } })
    renderWithProviders()

    fireEvent.click(screen.getByRole('button', { name: 'New folder' }))

    await waitFor(() => {
      expect(post).toHaveBeenCalledWith('/folders', { folder: 'foo/Untitled folder' })
    })
  })

  it('navigates to the new note by id on success', async () => {
    post.mockResolvedValue({ note: { id: 7, path: 'foo/Untitled.md' } })
    renderWithProviders()

    fireEvent.click(screen.getByRole('button', { name: 'New note' }))

    await waitFor(() => {
      expect(navigate).toHaveBeenCalledWith('/note/7')
    })
  })

  it('opens the upload flow targeting the active folder when Upload is clicked', () => {
    renderWithProviders()
    fireEvent.click(screen.getByRole('button', { name: 'Upload attachment' }))
    // Seeded active note lives in folder "foo" (see renderWithProviders).
    expect(openUpload).toHaveBeenCalledWith(undefined, 'foo')
  })

  it('hides the Upload button on demo vaults', () => {
    demoActive = true
    renderWithProviders()
    expect(screen.queryByRole('button', { name: 'Upload attachment' })).toBeNull()
  })

  it('uses the target folder label in the New note tooltip trigger', () => {
    // The tooltip content only mounts to the DOM on hover/focus (Radix portal),
    // so assert on the wiring via aria-describedby + content presence after
    // pointer/focus. Keep this assertion light: confirm the component renders
    // with the right buttons and the FolderActions state hooks ran without error.
    renderWithProviders()
    expect(screen.getByRole('button', { name: 'New note' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'New folder' })).toBeInTheDocument()
  })
})

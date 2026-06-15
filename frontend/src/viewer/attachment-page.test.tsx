import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router'
import { beforeAll, beforeEach, expect, it, vi } from 'vitest'
import AttachmentPage from './attachment-page'
import { api } from '../api/client'
import type { AttachmentSummary } from '../api/queries'

// Stub the heavy pdf.js viewer — this suite only verifies routing-by-mime, not
// pdf.js rendering (covered in pdf-view.test.tsx).
vi.mock('./pdf-view', () => ({
  default: ({ filename }: { filename: string }) => <div data-testid="pdf-view">pdf {filename}</div>,
}))

// AttachmentPage resolves the route :id against the attachments list. Drive that
// list from the test (must be `mock*`-prefixed for vitest's vi.mock hoist guard).
let mockAttachments: AttachmentSummary[] = []
let mockLoading = false
vi.mock('../api/queries', () => ({
  useAttachments: () => ({ data: mockAttachments, isLoading: mockLoading }),
}))

const att = (over: Partial<AttachmentSummary> & { id: string }): AttachmentSummary => ({
  path: 'doc.pdf',
  mime_type: 'application/pdf',
  size_bytes: 1,
  mtime: 0,
  updated_at: '',
  ...over,
})

beforeAll(() => {
  URL.createObjectURL = vi.fn(() => 'blob:fake')
  URL.revokeObjectURL = vi.fn()
})

beforeEach(() => {
  mockAttachments = []
  mockLoading = false
  vi.restoreAllMocks()
})

function renderAt(id: string) {
  return render(
    <MemoryRouter initialEntries={[`/note/${id}`]}>
      <Routes>
        <Route path="/note/:id" element={<AttachmentPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

it('renders an <img> for an image attachment, fetching bytes by path', async () => {
  mockAttachments = [att({ id: 'img-1', path: 'img/a.png', mime_type: 'image/png' })]
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'image/png' }))
  renderAt('img-1')
  await waitFor(() => expect(screen.getByRole('img')).toBeInTheDocument())
  expect(api.getBlob).toHaveBeenCalledWith('/attachments/img/a.png?raw=1')
})

it('renders the pdf.js viewer for a pdf attachment', async () => {
  mockAttachments = [att({ id: 'pdf-1', path: 'reports/q3.pdf' })]
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'application/pdf' }))
  renderAt('pdf-1')
  await waitFor(() => expect(screen.getByTestId('pdf-view')).toBeInTheDocument())
  expect(screen.getByTestId('pdf-view')).toHaveTextContent('q3.pdf')
})

it('renders a download fallback for unsupported types', async () => {
  mockAttachments = [att({ id: 'zip-1', path: 'a.zip', mime_type: 'application/zip' })]
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'application/zip' }))
  renderAt('zip-1')
  await waitFor(() => expect(screen.getByRole('link', { name: /download/i })).toBeInTheDocument())
})

it('shows an error state when the byte fetch fails', async () => {
  mockAttachments = [att({ id: 'img-1', path: 'missing.png', mime_type: 'image/png' })]
  vi.spyOn(api, 'getBlob').mockRejectedValueOnce(new Error('boom'))
  renderAt('img-1')
  await waitFor(() => expect(screen.getByText(/couldn.t load/i)).toBeInTheDocument())
})

it('shows a loading state before the bytes resolve', () => {
  mockAttachments = [att({ id: 'img-1', path: 'slow.png', mime_type: 'image/png' })]
  vi.spyOn(api, 'getBlob').mockReturnValueOnce(new Promise<Blob>(() => {}))
  renderAt('img-1')
  expect(screen.getByText(/loading slow\.png/i)).toBeInTheDocument()
})

it('shows "not found" when no attachment matches the id', () => {
  mockAttachments = [att({ id: 'other' })]
  renderAt('missing-id')
  expect(screen.getByText(/not found/i)).toBeInTheDocument()
})

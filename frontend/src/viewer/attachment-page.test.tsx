import { render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router'
import { beforeAll, expect, it, vi } from 'vitest'
import AttachmentPage from './attachment-page'
import { api } from '../api/client'

// Stub the heavy pdf.js viewer — this suite only verifies routing-by-mime, not
// pdf.js rendering (covered in pdf-view.test.tsx).
vi.mock('./pdf-view', () => ({
  default: ({ filename }: { filename: string }) => <div data-testid="pdf-view">pdf {filename}</div>,
}))

beforeAll(() => {
  URL.createObjectURL = vi.fn(() => 'blob:fake')
  URL.revokeObjectURL = vi.fn()
})

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[`/attachment/${path}`]}>
      <Routes>
        <Route path="/attachment/*" element={<AttachmentPage />} />
      </Routes>
    </MemoryRouter>,
  )
}

it('renders an <img> for an image attachment', async () => {
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'image/png' }))
  renderAt('img/a.png')
  await waitFor(() => expect(screen.getByRole('img')).toBeInTheDocument())
  expect(api.getBlob).toHaveBeenCalledWith('/attachments/img/a.png?raw=1')
})

it('renders the pdf.js viewer for a pdf attachment', async () => {
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'application/pdf' }))
  renderAt('doc.pdf')
  await waitFor(() => expect(screen.getByTestId('pdf-view')).toBeInTheDocument())
  expect(screen.getByTestId('pdf-view')).toHaveTextContent('doc.pdf')
})

it('renders a download fallback for unsupported types', async () => {
  vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'application/zip' }))
  renderAt('a.zip')
  await waitFor(() => expect(screen.getByRole('link', { name: /download/i })).toBeInTheDocument())
})

it('shows an error state when the fetch fails', async () => {
  vi.spyOn(api, 'getBlob').mockRejectedValueOnce(new Error('boom'))
  renderAt('missing.png')
  await waitFor(() => expect(screen.getByText(/couldn.t load/i)).toBeInTheDocument())
})

it('shows a loading state before the fetch resolves', () => {
  // A promise that never resolves keeps the component in its loading branch.
  vi.spyOn(api, 'getBlob').mockReturnValueOnce(new Promise<Blob>(() => {}))
  renderAt('slow.png')
  expect(screen.getByText(/loading slow\.png/i)).toBeInTheDocument()
})

import { render, screen } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router'
import { expect, it, vi } from 'vitest'
import type { AttachmentSummary } from '../api/queries'

// Stub both heavy viewers — this suite only verifies the note-vs-attachment
// routing decision, not their rendering.
vi.mock('./note-page', () => ({ default: () => <div data-testid="note-page" /> }))
vi.mock('./attachment-page', () => ({ default: () => <div data-testid="attachment-page" /> }))

let mockAttachments: AttachmentSummary[] = []
vi.mock('../api/queries', () => ({
  useAttachments: () => ({ data: mockAttachments, isLoading: false }),
}))

import VaultItemPage from './vault-item-page'

const att = (id: string): AttachmentSummary => ({
  id,
  path: `${id}.png`,
  mime_type: 'image/png',
  size_bytes: 1,
  mtime: 0,
  updated_at: '',
})

async function renderAt(id: string) {
  render(
    <MemoryRouter initialEntries={[`/note/${id}`]}>
      <Routes>
        <Route path="/note/:id" element={<VaultItemPage />} />
      </Routes>
    </MemoryRouter>,
  )
  // Let the lazy child resolve.
  await screen.findByTestId(/page$/)
}

it('renders the attachment viewer when the id is in the attachments list', async () => {
  mockAttachments = [att('file-1')]
  await renderAt('file-1')
  expect(screen.getByTestId('attachment-page')).toBeInTheDocument()
  expect(screen.queryByTestId('note-page')).not.toBeInTheDocument()
})

it('renders the note viewer when the id is not an attachment', async () => {
  mockAttachments = [att('file-1')]
  await renderAt('note-99')
  expect(screen.getByTestId('note-page')).toBeInTheDocument()
  expect(screen.queryByTestId('attachment-page')).not.toBeInTheDocument()
})

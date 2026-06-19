import { describe, expect, it, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { AttachmentUploadDialog } from './upload-dialog'
import { ApiError, LimitExceededError } from '@/api/client'

const mutateAsync = vi.fn()
vi.mock('@/api/queries', () => ({
  useUploadAttachment: () => ({ mutateAsync }),
}))
vi.mock('./file-to-base64', () => ({ fileToBase64: () => Promise.resolve('AAAA') }))

function file(name: string, type = 'text/plain') {
  return new File([new Uint8Array([1, 2, 3])], name, { type })
}

beforeEach(() => {
  mutateAsync.mockReset()
})

describe('AttachmentUploadDialog', () => {
  it('lists the files and uploads each with folder-prefixed path', async () => {
    mutateAsync.mockResolvedValue({ attachment: { id: 'x', path: 'docs/a.txt' } })
    render(
      <AttachmentUploadDialog
        initialFiles={[file('a.txt')]}
        folders={[{ name: 'docs' }]}
        onClose={() => {}}
      />,
    )
    expect(screen.getByText('a.txt')).toBeInTheDocument()

    // pick folder "docs"
    fireEvent.click(screen.getByRole('option', { name: 'docs' }))
    fireEvent.click(screen.getByRole('button', { name: /^upload$/i }))

    await waitFor(() =>
      expect(mutateAsync).toHaveBeenCalledWith(
        expect.objectContaining({ path: 'docs/a.txt', content_base64: 'AAAA' }),
      ),
    )
  })

  it('uploads to root when no folder is picked', async () => {
    mutateAsync.mockResolvedValue({ attachment: { id: 'x', path: 'a.txt' } })
    render(<AttachmentUploadDialog initialFiles={[file('a.txt')]} folders={[]} onClose={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /^upload$/i }))
    await waitFor(() =>
      expect(mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ path: 'a.txt' })),
    )
  })

  it('marks a row errored on 415 without blocking the others', async () => {
    mutateAsync
      .mockRejectedValueOnce(new ApiError(415, 'mime_not_allowed'))
      .mockResolvedValueOnce({ attachment: { id: 'y', path: 'b.txt' } })
    render(
      <AttachmentUploadDialog
        initialFiles={[file('a.exe', 'application/x-msdownload'), file('b.txt')]}
        folders={[]}
        onClose={() => {}}
      />,
    )
    fireEvent.click(screen.getByRole('button', { name: /^upload$/i }))
    await waitFor(() => expect(screen.getByText(/not allowed/i)).toBeInTheDocument())
    expect(mutateAsync).toHaveBeenCalledTimes(2)
  })

  it('shows an upgrade hint on a 402 LimitExceededError', async () => {
    mutateAsync.mockRejectedValue(
      new LimitExceededError('attachments_disabled', 'attachments_enabled', false, null, null),
    )
    render(<AttachmentUploadDialog initialFiles={[file('a.txt')]} folders={[]} onClose={() => {}} />)
    fireEvent.click(screen.getByRole('button', { name: /^upload$/i }))
    await waitFor(() => expect(screen.getByText(/upgrade to upload/i)).toBeInTheDocument())
  })
})

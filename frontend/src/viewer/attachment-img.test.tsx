import { beforeAll, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import AttachmentImg from './attachment-img'
import { api, ApiError } from '../api/client'

beforeAll(() => {
  // jsdom lacks createObjectURL/revokeObjectURL
  URL.createObjectURL = vi.fn(() => 'blob:fake')
  URL.revokeObjectURL = vi.fn()
})

it('fetches the attachment with ?raw=1 and renders an img', async () => {
  const spy = vi.spyOn(api, 'getBlob').mockResolvedValueOnce(new Blob(['x'], { type: 'image/png' }))
  render(<AttachmentImg path="img/a.png" alt="A" />)
  await waitFor(() => expect(screen.getByRole('img')).toBeInTheDocument())
  expect(spy).toHaveBeenCalledWith('/attachments/img/a.png?raw=1')
})

it('says "Missing attachment" only on a real 404', async () => {
  vi.spyOn(api, 'getBlob').mockRejectedValueOnce(new ApiError(404, 'not found'))
  render(<AttachmentImg path="img/a.png" />)
  await waitFor(() => expect(screen.getByText(/missing attachment/i)).toBeInTheDocument())
})

it('does NOT claim "missing" on a transient 5xx — says temporarily unavailable', async () => {
  vi.spyOn(api, 'getBlob').mockRejectedValueOnce(new ApiError(502, 'storage down'))
  render(<AttachmentImg path="img/a.png" />)
  await waitFor(() => expect(screen.getByText(/temporarily unavailable/i)).toBeInTheDocument())
  expect(screen.queryByText(/missing attachment/i)).not.toBeInTheDocument()
})

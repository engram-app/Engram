import { beforeAll, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import AttachmentImg from './attachment-img'
import { api } from '../api/client'

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

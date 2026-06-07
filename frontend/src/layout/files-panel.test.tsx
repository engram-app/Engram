import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { describe, expect, it } from 'vitest'
import FilesPanel from './files-panel'

function renderPanel() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter><FilesPanel /></MemoryRouter>
    </QueryClientProvider>,
  )
}

describe('FilesPanel', () => {
  it('renders the panel header "Files"', () => {
    renderPanel()
    expect(screen.getByRole('heading', { name: 'Files', level: 2 })).toBeInTheDocument()
  })

  it('mounts the folder tree region', () => {
    renderPanel()
    expect(screen.getByTestId('folder-tree-root')).toBeInTheDocument()
  })
})

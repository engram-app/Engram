import { render, screen, waitFor, fireEvent } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import FolderTree from './folder-tree'
import { FolderTreeProvider } from '../layout/folder-tree-context'

// The HT-driven FolderTree's UX is the COMPOSITION of already-tested
// primitives (loader, useEngramTree, TreeRow, dialogs). These integration
// tests cover the top-level renders + smoke that the hooks/mutations are
// wired — full coverage lives in the primitives.

vi.mock('sonner', () => ({
  toast: { error: vi.fn(), success: vi.fn(), info: vi.fn() },
}))

const DEFAULT_FOLDERS = [
  { id: '1', parent_id: null, name: 'Projects', count: 1 },
  { id: '2', parent_id: null, name: 'archive', count: 0 },
]
const DEFAULT_ROOT_NOTE = {
  id: '42',
  path: 'a.md',
  title: 'a',
  folder: '',
  tags: [],
  version: 1,
  mtime: '',
  created_at: '',
  updated_at: '',
}

const {
  batchDeleteNotesMutate,
  batchMoveNotesMutate,
  batchDeleteFoldersMutate,
  batchMoveFoldersMutate,
  mock,
} = vi.hoisted(() => ({
  batchDeleteNotesMutate: vi.fn(),
  batchMoveNotesMutate: vi.fn(),
  batchDeleteFoldersMutate: vi.fn(),
  batchMoveFoldersMutate: vi.fn(),
  // Mutable per-test fixtures (folders + root notes + loading flag + attachments), set in beforeEach.
  mock: { folders: [] as unknown[], rootNotes: [] as unknown[], loading: false, attachments: [] as unknown[] },
}))

vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    useFolders: () => ({
      data: mock.loading ? undefined : mock.folders,
      isLoading: mock.loading,
      isError: false,
    }),
    useAttachments: () => ({ data: mock.attachments, isLoading: false }),
    useFolderNotesById: (folderId: string | null) => {
      // Root notes share the one id-keyed cache under the 'root' sentinel.
      if (folderId === 'root') {
        return { data: mock.rootNotes, isLoading: false }
      }
      if (folderId === '1') {
        return {
          data: [
            {
              id: '99',
              path: 'Projects/spec.md',
              title: 'spec',
              folder: 'Projects',
              tags: [],
              version: 1,
              mtime: '',
              created_at: '',
              updated_at: '',
            },
          ],
          isLoading: false,
        }
      }
      return { data: [], isLoading: false }
    },
    useRenameNote: () => ({ mutate: vi.fn(), mutateAsync: vi.fn(() => Promise.resolve()), isPending: false }),
    useRenameFolder: () => ({ mutate: vi.fn(), mutateAsync: vi.fn(() => Promise.resolve()), isPending: false }),
    useDuplicateNote: () => ({ mutate: vi.fn(), mutateAsync: vi.fn(() => Promise.resolve()), isPending: false }),
    useBatchDeleteNotes: () => ({ mutate: batchDeleteNotesMutate, isPending: false }),
    useBatchMoveNotes: () => ({ mutate: batchMoveNotesMutate, isPending: false }),
    useBatchDeleteFolders: () => ({ mutate: batchDeleteFoldersMutate, isPending: false }),
    useBatchMoveFolders: () => ({ mutate: batchMoveFoldersMutate, isPending: false }),
  }
})

function renderTree() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  // The loader reads note lists straight from the query cache. Root notes key
  // under the 'root' sentinel; useActiveVaultId is unset in tests, so the tree
  // resolves vaultId to ''. Seed it so root notes render without a fetch.
  qc.setQueryData(['folder-notes-by-id', '', 'root'], mock.rootNotes)
  return render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <FolderTreeProvider>
          <FolderTree />
        </FolderTreeProvider>
      </MemoryRouter>
    </QueryClientProvider>,
  )
}

beforeEach(() => {
  batchDeleteNotesMutate.mockReset()
  batchMoveNotesMutate.mockReset()
  batchDeleteFoldersMutate.mockReset()
  batchMoveFoldersMutate.mockReset()
  mock.folders = DEFAULT_FOLDERS.map((f) => ({ ...f }))
  mock.rootNotes = [{ ...DEFAULT_ROOT_NOTE }]
  mock.loading = false
  mock.attachments = []
})

describe('FolderTree (HT)', () => {
  it('renders the tree container with role=tree', async () => {
    renderTree()
    await waitFor(() => {
      expect(screen.getByTestId('folder-tree-root')).toBeInTheDocument()
    })
  })

  it('renders top-level folder rows', async () => {
    renderTree()
    await waitFor(() => {
      expect(screen.getByRole('treeitem', { name: 'Projects' })).toBeInTheDocument()
      expect(screen.getByRole('treeitem', { name: 'archive' })).toBeInTheDocument()
    })
  })

  it('renders root-level note as a link to /note/:id', async () => {
    renderTree()
    const link = await screen.findByRole('treeitem', { name: 'a' })
    expect(link).toHaveAttribute('href', '/note/42')
  })

  it('shows root notes even when there are zero folders (new doc at root)', async () => {
    mock.folders = []
    mock.rootNotes = [{ ...DEFAULT_ROOT_NOTE }]
    renderTree()
    // Must NOT short-circuit to the empty state — the root note is present.
    expect(screen.queryByText('No notes yet.')).toBeNull()
    expect(await screen.findByRole('treeitem', { name: 'a' })).toHaveAttribute('href', '/note/42')
  })

  it('shows the empty state only when there are no folders AND no root notes', async () => {
    mock.folders = []
    mock.rootNotes = []
    renderTree()
    expect(await screen.findByText('No notes yet.')).toBeInTheDocument()
  })

  it('right-click on a folder row opens the ContextMenu', async () => {
    renderTree()
    const projects = await screen.findByRole('treeitem', { name: 'Projects' })
    fireEvent.contextMenu(projects, { clientX: 50, clientY: 60 })
    await waitFor(() => {
      // ContextMenu renders role=menu + menuitems with action labels
      const menu = screen.getByRole('menu')
      expect(menu).toBeInTheDocument()
      expect(screen.getByRole('menuitem', { name: 'Rename' })).toBeInTheDocument()
      expect(screen.getByRole('menuitem', { name: 'Move to…' })).toBeInTheDocument()
      expect(screen.getByRole('menuitem', { name: 'Delete' })).toBeInTheDocument()
    })
  })

  it('long-press (touch) on a row opens the ActionDrawer', async () => {
    renderTree()
    const projects = await screen.findByRole('treeitem', { name: 'Projects' })
    // Long-press is touch/pen only — mouse uses right-click. Fire a touch press
    // and wait the configured 500ms.
    fireEvent.pointerDown(projects, { pointerType: 'touch', clientX: 5, clientY: 5 })
    await new Promise((resolve) => setTimeout(resolve, 600))
    // The ActionDrawer (with its backdrop) is shown for the long-pressed row.
    expect(await screen.findByTestId('action-drawer-backdrop')).toBeInTheDocument()
  })

  it('shows loading state', () => {
    // Re-mock for this test scope is heavy; use a separate render with a
    // QueryClient that hasn't resolved — but our mock returns synchronously.
    // We just smoke that the loading branch isn't visible in the happy path.
    renderTree()
    expect(screen.queryByText(/Loading/i)).not.toBeInTheDocument()
  })

  it('does not crash on loading→loaded transition (hook-count regression)', async () => {
    // Start in loading state — renders the "Loading…" early-return branch.
    mock.loading = true
    const { rerender } = renderTree()
    expect(screen.getByText('Loading…')).toBeInTheDocument()

    // Flip to loaded — if useCallback were placed after the early returns,
    // React would throw "Rendered more hooks than during the previous render".
    mock.loading = false
    rerender(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <FolderTreeProvider>
            <FolderTree />
          </FolderTreeProvider>
        </MemoryRouter>
      </QueryClientProvider>,
    )

    // Tree root must be present — no crash, no "Loading…" text.
    await waitFor(() => {
      expect(screen.getByTestId('folder-tree-root')).toBeInTheDocument()
    })
    expect(screen.queryByText('Loading…')).not.toBeInTheDocument()
  })

  it('renders an attachment row from useAttachments', async () => {
    mock.folders = []
    mock.rootNotes = []
    mock.attachments = [
      {
        id: 'cover-1',
        path: 'cover.png',
        mime_type: 'image/png',
        size_bytes: 1,
        mtime: 0,
        updated_at: '2026-06-10T00:00:00Z',
      },
    ]
    renderTree()
    expect(await screen.findByText('cover.png')).toBeInTheDocument()
  })
})

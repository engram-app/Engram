import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { describe, expect, it, vi, beforeEach } from 'vitest'
import FolderTree from './folder-tree'
import { FolderTreeProvider } from '../layout/folder-tree-context'
import { ApiError } from '../api/client'

// ── Mutation spies (hoisted so vi.mock can see them) ─────────
const {
  renameNoteMutate,
  renameFolderMutate,
  deleteNoteMutate,
  deleteFolderMutate,
  createNoteMutate,
  duplicateNoteMutate,
  renameNoteError,
  setRenameNoteError,
} = vi.hoisted(() => {
  let renameNoteErr: ApiError | null = null
  return {
    renameNoteMutate: vi.fn(),
    renameFolderMutate: vi.fn(),
    deleteNoteMutate: vi.fn(),
    deleteFolderMutate: vi.fn(),
    createNoteMutate: vi.fn(),
    duplicateNoteMutate: vi.fn(),
    renameNoteError: () => renameNoteErr,
    setRenameNoteError: (e: ApiError | null) => {
      renameNoteErr = e
    },
  }
})

vi.mock('../api/queries', async () => {
  const actual = await vi.importActual<typeof import('../api/queries')>('../api/queries')
  return {
    ...actual,
    useFolders: () => ({
      data: [
        { name: '', count: 1 },
        { name: 'docs', count: 1 },
        { name: 'archive', count: 0 },
      ],
      isLoading: false,
      isError: false,
    }),
    useFolderNotes: (folder: string) => {
      if (folder === '') {
        return {
          data: [
            {
              path: 'a.md',
              title: 'a',
              folder: '',
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
      if (folder === 'docs') {
        return {
          data: [
            {
              path: 'docs/spec.md',
              title: 'spec',
              folder: 'docs',
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
    useRenameNote: () => ({
      mutate: renameNoteMutate,
      mutateAsync: vi.fn((vars: { old_path: string; new_path: string }) => {
        const err = renameNoteError()
        renameNoteMutate(vars)
        return err ? Promise.reject(err) : Promise.resolve({ renamed: true, ...vars })
      }),
      isPending: false,
    }),
    useRenameFolder: () => ({
      mutate: renameFolderMutate,
      mutateAsync: vi.fn((vars: { old_path: string; new_path: string }) => {
        renameFolderMutate(vars)
        return Promise.resolve({ renamed: true, ...vars, count: 0 })
      }),
      isPending: false,
    }),
    useDeleteNote: () => ({
      mutate: deleteNoteMutate,
      mutateAsync: vi.fn((vars: { path: string }) => {
        deleteNoteMutate(vars)
        return Promise.resolve({ deleted: true })
      }),
      isPending: false,
    }),
    useDeleteFolder: () => ({
      mutate: deleteFolderMutate,
      mutateAsync: vi.fn((vars: { path: string }) => {
        deleteFolderMutate(vars)
        return Promise.resolve({ deleted: true })
      }),
      isPending: false,
    }),
    useCreateNote: () => ({
      mutate: createNoteMutate,
      mutateAsync: vi.fn((vars: { folder: string }) => {
        createNoteMutate(vars)
        return Promise.resolve({ path: vars.folder ? `${vars.folder}/Untitled.md` : 'Untitled.md' })
      }),
      isPending: false,
    }),
    useDuplicateNote: () => ({
      mutate: duplicateNoteMutate,
      mutateAsync: vi.fn((vars: { src_path: string; new_path: string }) => {
        duplicateNoteMutate(vars)
        return Promise.resolve({ note: { path: vars.new_path, content: 'hi' } })
      }),
      isPending: false,
    }),
  }
})

function renderTree() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
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
  renameNoteMutate.mockReset()
  renameFolderMutate.mockReset()
  deleteNoteMutate.mockReset()
  deleteFolderMutate.mockReset()
  createNoteMutate.mockReset()
  duplicateNoteMutate.mockReset()
  setRenameNoteError(null)
})

describe('FolderTree tree actions', () => {
  it('opens a context menu with file actions on right-click of a note row', () => {
    renderTree()
    const link = screen.getByRole('link', { name: /a/i })
    fireEvent.contextMenu(link)

    expect(screen.getByRole('menu')).toBeInTheDocument()
    expect(screen.getByRole('menuitem', { name: 'Rename' })).toBeInTheDocument()
    expect(screen.getByRole('menuitem', { name: 'Delete' })).toBeInTheDocument()
    expect(screen.getByRole('menuitem', { name: 'Copy wikilink' })).toBeInTheDocument()
  })

  it('Rename swaps row to inline input and Enter calls renameNote with new path', async () => {
    renderTree()
    const link = screen.getByRole('link', { name: /a/i })
    fireEvent.contextMenu(link)
    fireEvent.click(screen.getByRole('menuitem', { name: 'Rename' }))

    const input = await screen.findByRole('textbox')
    expect(input).toHaveValue('a.md')
    fireEvent.change(input, { target: { value: 'b.md' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => {
      expect(renameNoteMutate).toHaveBeenCalledWith({ old_path: 'a.md', new_path: 'b.md' })
    })
  })

  it('Delete shows confirm dialog, clicking Delete fires deleteNote', async () => {
    renderTree()
    const link = screen.getByRole('link', { name: /a/i })
    fireEvent.contextMenu(link)
    fireEvent.click(screen.getByRole('menuitem', { name: 'Delete' }))

    const confirmBtn = await screen.findByRole('button', { name: 'Delete' })
    fireEvent.click(confirmBtn)

    await waitFor(() => {
      expect(deleteNoteMutate).toHaveBeenCalledWith({ path: 'a.md' })
    })
  })

  it('Duplicate fires duplicateNote with src + collision-free new path', async () => {
    renderTree()
    const link = screen.getByRole('link', { name: /a/i })
    fireEvent.contextMenu(link)
    fireEvent.click(screen.getByRole('menuitem', { name: 'Duplicate' }))

    await waitFor(() => {
      expect(duplicateNoteMutate).toHaveBeenCalledWith({
        src_path: 'a.md',
        new_path: 'a (copy).md',
      })
    })
  })

  it('drag note onto folder row fires renameNote with computed new path', async () => {
    renderTree()
    const noteLink = screen.getByRole('link', { name: /a/i })
    const folderBtn = screen.getByRole('button', { name: /docs/i, expanded: false })

    // Build a DataTransfer-like that survives across events
    const data = new Map<string, string>()
    const dataTransfer = {
      setData: (k: string, v: string) => data.set(k, v),
      getData: (k: string) => data.get(k) ?? '',
      types: [] as string[],
      effectAllowed: 'move',
      dropEffect: 'move',
    }
    // populate types lazily from data
    Object.defineProperty(dataTransfer, 'types', {
      get: () => Array.from(data.keys()),
    })

    fireEvent.dragStart(noteLink, { dataTransfer })
    fireEvent.dragOver(folderBtn, { dataTransfer })
    fireEvent.drop(folderBtn, { dataTransfer })

    await waitFor(() => {
      expect(renameNoteMutate).toHaveBeenCalled()
    })
    // mutate() is called with (vars, options); we only care about vars.
    expect(renameNoteMutate.mock.calls[0]?.[0]).toEqual({
      old_path: 'a.md',
      new_path: 'docs/a.md',
    })
  })

  it('409 from rename keeps row in edit mode with error visible', async () => {
    setRenameNoteError(new ApiError(409, 'conflict'))
    renderTree()
    const link = screen.getByRole('link', { name: /a/i })
    fireEvent.contextMenu(link)
    fireEvent.click(screen.getByRole('menuitem', { name: 'Rename' }))

    const input = await screen.findByRole('textbox')
    fireEvent.change(input, { target: { value: 'b.md' } })
    fireEvent.keyDown(input, { key: 'Enter' })

    await waitFor(() => {
      expect(renameNoteMutate).toHaveBeenCalled()
    })
    // Row should still be in rename mode (input still mounted) and error visible
    expect(await screen.findByRole('alert')).toHaveTextContent(/already exists|conflict|exists/i)
    expect(screen.getByRole('textbox')).toBeInTheDocument()
  })
})

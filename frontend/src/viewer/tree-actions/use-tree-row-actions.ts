import { useCallback, useState } from 'react'
import { toast } from 'sonner'
import { ApiError } from '../../api/client'
import {
  useDeleteFolder,
  useDeleteNote,
  useRenameFolder,
  useRenameNote,
} from '../../api/queries'
import type { DragNode } from './use-tree-drag'
import { isValidDropTarget, newPathAfterMove } from './use-tree-drag'

const DRAG_MIME = 'application/x-engram-node'

type RowKind = 'file' | 'folder'

interface Row {
  kind: RowKind
  path: string
  label: string
}

interface UseTreeRowActionsResult {
  // UI state
  menuPos: { x: number; y: number } | null
  drawerOpen: boolean
  renaming: boolean
  showDelete: boolean
  showMove: boolean
  renameError: string | undefined

  // Openers
  openContextMenu: (pos: { x: number; y: number }) => void
  openDrawer: () => void
  closeMenu: () => void
  closeDrawer: () => void
  startRename: () => void
  startDelete: () => void
  startMove: () => void
  copyWikilink: (label: string) => Promise<void>

  // Commit handlers
  commitRename: (next: string) => Promise<void>
  cancelRename: () => void
  confirmDelete: () => Promise<void>
  cancelDelete: () => void
  commitMove: (folder: string) => Promise<void>
  cancelMove: () => void

  // Drag helpers
  dragSourceProps: {
    draggable: true
    onDragStart: (e: React.DragEvent) => void
  }
  dropTargetProps: (targetFolder: string) => {
    onDragOver: (e: React.DragEvent) => void
    onDrop: (e: React.DragEvent) => void
  }
}

export function useTreeRowActions(row: Row): UseTreeRowActionsResult {
  const [menuPos, setMenuPos] = useState<{ x: number; y: number } | null>(null)
  const [drawerOpen, setDrawerOpen] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [showDelete, setShowDelete] = useState(false)
  const [showMove, setShowMove] = useState(false)
  const [renameError, setRenameError] = useState<string | undefined>(undefined)

  const renameNote = useRenameNote()
  const renameFolder = useRenameFolder()
  const deleteNote = useDeleteNote()
  const deleteFolder = useDeleteFolder()

  const closeMenu = useCallback(() => setMenuPos(null), [])
  const closeDrawer = useCallback(() => setDrawerOpen(false), [])
  const openContextMenu = useCallback((pos: { x: number; y: number }) => setMenuPos(pos), [])
  const openDrawer = useCallback(() => setDrawerOpen(true), [])

  const startRename = useCallback(() => {
    setRenameError(undefined)
    setRenaming(true)
  }, [])
  const cancelRename = useCallback(() => {
    setRenaming(false)
    setRenameError(undefined)
  }, [])
  const startDelete = useCallback(() => setShowDelete(true), [])
  const cancelDelete = useCallback(() => setShowDelete(false), [])
  const startMove = useCallback(() => setShowMove(true), [])
  const cancelMove = useCallback(() => setShowMove(false), [])

  const computeNewPath = useCallback(
    (newName: string): string => {
      // Replace the last segment of the path with newName.
      const slash = row.path.lastIndexOf('/')
      const folder = slash < 0 ? '' : row.path.slice(0, slash)
      return folder ? `${folder}/${newName}` : newName
    },
    [row.path],
  )

  const commitRename = useCallback(
    async (next: string) => {
      const newPath = computeNewPath(next)
      if (newPath === row.path) {
        cancelRename()
        return
      }
      const mutation = row.kind === 'file' ? renameNote : renameFolder
      try {
        await mutation.mutateAsync({ old_path: row.path, new_path: newPath })
        setRenaming(false)
        setRenameError(undefined)
        toast.success(`Renamed to ${next}`)
      } catch (err) {
        if (err instanceof ApiError && err.status === 409) {
          setRenameError(`A ${row.kind === 'file' ? 'file' : 'folder'} with that name already exists.`)
        } else if (err instanceof ApiError && err.status === 404) {
          toast.error('Item no longer exists.')
          setRenaming(false)
        } else {
          setRenameError('Rename failed.')
        }
      }
    },
    [row.path, row.kind, computeNewPath, renameNote, renameFolder, cancelRename],
  )

  const confirmDelete = useCallback(async () => {
    const mutation = row.kind === 'file' ? deleteNote : deleteFolder
    try {
      await mutation.mutateAsync({ path: row.path })
      setShowDelete(false)
      toast.success(`Deleted ${row.label}`)
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        toast.error('Item no longer exists.')
        setShowDelete(false)
      } else {
        toast.error('Delete failed.')
      }
    }
  }, [row.kind, row.path, row.label, deleteNote, deleteFolder])

  const commitMove = useCallback(
    async (targetFolder: string) => {
      const src: DragNode = { kind: row.kind, path: row.path }
      if (!isValidDropTarget(src, targetFolder)) {
        setShowMove(false)
        return
      }
      const newPath = newPathAfterMove(row.path, targetFolder)
      const mutation = row.kind === 'file' ? renameNote : renameFolder
      try {
        await mutation.mutateAsync({ old_path: row.path, new_path: newPath })
        setShowMove(false)
        toast.success(`Moved to ${targetFolder === '' ? '/' : targetFolder}`)
      } catch (err) {
        if (err instanceof ApiError && err.status === 409) {
          toast.error('Target already has an item with that name.')
        } else {
          toast.error('Move failed.')
        }
      }
    },
    [row.kind, row.path, renameNote, renameFolder],
  )

  const copyWikilink = useCallback(async (label: string) => {
    try {
      await navigator.clipboard.writeText(`[[${label}]]`)
      toast.success('Wikilink copied')
    } catch {
      toast.error('Could not copy to clipboard')
    }
  }, [])

  const dragSourceProps = {
    draggable: true as const,
    onDragStart: (e: React.DragEvent) => {
      const payload: DragNode = { kind: row.kind, path: row.path }
      e.dataTransfer.setData(DRAG_MIME, JSON.stringify(payload))
      e.dataTransfer.effectAllowed = 'move'
    },
  }

  const dropTargetProps = (targetFolder: string) => ({
    onDragOver: (e: React.DragEvent) => {
      if (!e.dataTransfer.types.includes(DRAG_MIME)) return
      e.preventDefault()
      e.dataTransfer.dropEffect = 'move'
    },
    onDrop: (e: React.DragEvent) => {
      e.preventDefault()
      const raw = e.dataTransfer.getData(DRAG_MIME)
      if (!raw) return
      let src: DragNode
      try {
        src = JSON.parse(raw) as DragNode
      } catch {
        return
      }
      if (!isValidDropTarget(src, targetFolder)) return
      const newPath = newPathAfterMove(src.path, targetFolder)
      const mutation = src.kind === 'file' ? renameNote : renameFolder
      mutation.mutate(
        { old_path: src.path, new_path: newPath },
        {
          onSuccess: () => {
            toast.success(`Moved to ${targetFolder === '' ? '/' : targetFolder}`)
          },
          onError: (err) => {
            if (err instanceof ApiError && err.status === 409) {
              toast.error('Target already has an item with that name.')
            } else {
              toast.error('Move failed.')
            }
          },
        },
      )
    },
  })

  return {
    menuPos,
    drawerOpen,
    renaming,
    showDelete,
    showMove,
    renameError,
    openContextMenu,
    openDrawer,
    closeMenu,
    closeDrawer,
    startRename,
    startDelete,
    startMove,
    copyWikilink,
    commitRename,
    cancelRename,
    confirmDelete,
    cancelDelete,
    commitMove,
    cancelMove,
    dragSourceProps,
    dropTargetProps,
  }
}

export { DRAG_MIME }

/**
 * Standalone drop-target hook for use at the FolderTree root level (drop on
 * empty tree area → move to root). Avoids the per-row state baggage of
 * `useTreeRowActions` since the tree root has no row identity, no rename/move
 * state, etc. — just needs `onDragOver` + `onDrop`.
 */
export function useTreeDrop() {
  const renameNote = useRenameNote()
  const renameFolder = useRenameFolder()

  const dropTargetProps = (targetFolder: string) => ({
    onDragOver: (e: React.DragEvent) => {
      if (!e.dataTransfer.types.includes(DRAG_MIME)) return
      e.preventDefault()
      e.dataTransfer.dropEffect = 'move'
    },
    onDrop: (e: React.DragEvent) => {
      e.preventDefault()
      const raw = e.dataTransfer.getData(DRAG_MIME)
      if (!raw) return
      let src: DragNode
      try {
        src = JSON.parse(raw) as DragNode
      } catch {
        return
      }
      if (!isValidDropTarget(src, targetFolder)) return
      const newPath = newPathAfterMove(src.path, targetFolder)
      const mutation = src.kind === 'file' ? renameNote : renameFolder
      mutation.mutate(
        { old_path: src.path, new_path: newPath },
        {
          onSuccess: () => {
            toast.success(`Moved to ${targetFolder === '' ? '/' : targetFolder}`)
          },
          onError: (err) => {
            if (err instanceof ApiError && err.status === 409) {
              toast.error('Target already has an item with that name.')
            } else {
              toast.error('Move failed.')
            }
          },
        },
      )
    },
  })

  return { dropTargetProps }
}

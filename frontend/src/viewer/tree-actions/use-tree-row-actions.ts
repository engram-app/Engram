import { useCallback, useState } from 'react'
import { toast } from 'sonner'
import {
  useDeleteFolder,
  useDeleteNote,
  useRenameFolder,
  useRenameNote,
} from '../../api/queries'
import type { DragNode } from './use-tree-drag'
import { isValidDropTarget, newPathAfterMove } from './use-tree-drag'

const DRAG_MIME = 'application/x-engram-node'

// `id` is required on file rows so `useDeleteNote` can target the by-id
// route + key the optimistic note-body cache. Folder rows don't have an
// id at the API level — folders are identified by path.
export type Row =
  | { kind: 'file'; id: number; path: string; label: string }
  | { kind: 'folder'; path: string; label: string }

// Module-scoped active-drag tracker. dataTransfer.getData() returns "" during
// dragover (per HTML spec — only readable on drop), so we stash the dragged
// node here on dragstart and read it back in dragover to decide whether to
// preventDefault (= "drop allowed" cursor) or skip it (= "no-drop" cursor).
// Module scope is fine because the OS only supports one drag at a time per
// window; a Context would be heavier with no real benefit.
let activeDrag: DragNode | null = null

// Move success uses a success toast on the assumption optimistic update
// already shows the row in the new spot — the toast confirms intent. The
// error toast is handled by the mutation itself (`useRenameNote` /
// `useRenameFolder` `onError`), so we don't double-toast here.
function moveSuccessToast(targetFolder: string) {
  toast.success(`Moved to ${targetFolder === '' ? '/' : targetFolder}`)
}

/**
 * Shared drop-target event wiring used by both `useTreeRowActions` (folder
 * rows) and `useTreeDrop` (tree root). Single source of truth for the drag
 * affordance contract:
 *
 *  - dragover preventDefaults ONLY when the drop would be valid → browser
 *    shows "no-drop" cursor over invalid targets (folder onto descendant,
 *    file already in target folder).
 *  - drop reads payload via dataTransfer (the source of truth), re-validates,
 *    and dispatches the appropriate rename mutation.
 */
function buildDropTargetProps(
  targetFolder: string,
  renameNote: ReturnType<typeof useRenameNote>,
  renameFolder: ReturnType<typeof useRenameFolder>,
) {
  return {
    onDragOver: (e: React.DragEvent) => {
      if (!e.dataTransfer.types.includes(DRAG_MIME)) return
      // Stop propagation so an outer drop target (e.g. the root <nav>) can't
      // override our "no" — without this, hovering an invalid target would
      // still show "drop allowed" because the parent re-preventDefaults.
      e.stopPropagation()
      // dataTransfer.getData is empty during dragover (HTML spec); consult
      // the stashed active drag node to decide whether to allow the drop.
      const src = activeDrag
      if (src && !isValidDropTarget(src, targetFolder)) return
      e.preventDefault()
      e.dataTransfer.dropEffect = 'move'
    },
    onDrop: (e: React.DragEvent) => {
      e.preventDefault()
      // Stop propagation so the root <nav> drop handler doesn't also fire
      // (would re-interpret the drop as "move to root" and either no-op or
      // produce the wrong target folder).
      e.stopPropagation()
      const raw = e.dataTransfer.getData(DRAG_MIME)
      if (!raw) return
      let src: DragNode
      try {
        src = JSON.parse(raw) as DragNode
      } catch {
        return
      }
      if (!isValidDropTarget(src, targetFolder)) {
        toast.info('No move — already there')
        return
      }
      const newPath = newPathAfterMove(src.path, targetFolder)
      const mutation = src.kind === 'file' ? renameNote : renameFolder
      // Fire-and-forget. The mutation's own onError toasts on failure
      // (and rolls back the optimistic cache); the success toast just
      // confirms what the user already sees.
      mutation.mutate(
        { old_path: src.path, new_path: newPath },
        { onSuccess: () => moveSuccessToast(targetFolder) },
      )
    },
  }
}

interface UseTreeRowActionsResult {
  // UI state
  menuPos: { x: number; y: number } | null
  drawerOpen: boolean
  renaming: boolean
  showDelete: boolean
  showMove: boolean

  // Openers
  openContextMenu: (pos: { x: number; y: number }) => void
  openDrawer: () => void
  closeMenu: () => void
  closeDrawer: () => void
  startRename: () => void
  startDelete: () => void
  startMove: () => void
  copyWikilink: (label: string) => Promise<void>

  // Commit handlers — fire-and-forget; the underlying mutations are
  // optimistic, so UI state closes immediately and errors surface as
  // toasts from the mutation's own onError handler.
  commitRename: (next: string) => void
  cancelRename: () => void
  confirmDelete: () => void
  cancelDelete: () => void
  commitMove: (folder: string) => void
  cancelMove: () => void

  // Drag helpers
  dragSourceProps: {
    draggable: true
    onDragStart: (e: React.DragEvent) => void
    onDragEnd: () => void
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

  const renameNote = useRenameNote()
  const renameFolder = useRenameFolder()
  const deleteNote = useDeleteNote()
  const deleteFolder = useDeleteFolder()

  const closeMenu = useCallback(() => setMenuPos(null), [])
  const closeDrawer = useCallback(() => setDrawerOpen(false), [])
  const openContextMenu = useCallback((pos: { x: number; y: number }) => setMenuPos(pos), [])
  const openDrawer = useCallback(() => setDrawerOpen(true), [])

  const startRename = useCallback(() => setRenaming(true), [])
  const cancelRename = useCallback(() => setRenaming(false), [])
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
    (next: string) => {
      const newPath = computeNewPath(next)
      if (newPath === row.path) {
        cancelRename()
        return
      }
      // Close UI immediately — the optimistic cache update in the
      // mutation's onMutate has already swapped the row's label/path.
      // Errors surface via the mutation's onError toast + cache rollback.
      setRenaming(false)
      const mutation = row.kind === 'file' ? renameNote : renameFolder
      mutation.mutate(
        { old_path: row.path, new_path: newPath },
        { onSuccess: () => toast.success(`Renamed to ${next}`) },
      )
    },
    [row.path, row.kind, computeNewPath, renameNote, renameFolder, cancelRename],
  )

  const confirmDelete = useCallback(() => {
    // Close confirm dialog immediately; optimistic update removes the
    // row from the tree so the user sees the deletion right away.
    setShowDelete(false)
    if (row.kind === 'file') {
      deleteNote.mutate(
        { id: row.id, path: row.path },
        { onSuccess: () => toast.success(`Deleted ${row.label}`) },
      )
    } else {
      deleteFolder.mutate(
        { path: row.path },
        { onSuccess: () => toast.success(`Deleted ${row.label}`) },
      )
    }
  }, [row, deleteNote, deleteFolder])

  const commitMove = useCallback(
    (targetFolder: string) => {
      const src: DragNode = { kind: row.kind, path: row.path }
      if (!isValidDropTarget(src, targetFolder)) {
        setShowMove(false)
        return
      }
      setShowMove(false)
      const newPath = newPathAfterMove(row.path, targetFolder)
      const mutation = row.kind === 'file' ? renameNote : renameFolder
      mutation.mutate(
        { old_path: row.path, new_path: newPath },
        {
          onSuccess: () =>
            toast.success(`Moved to ${targetFolder === '' ? '/' : targetFolder}`),
        },
      )
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
      activeDrag = payload
      e.dataTransfer.setData(DRAG_MIME, JSON.stringify(payload))
      e.dataTransfer.effectAllowed = 'move'
    },
    onDragEnd: () => {
      activeDrag = null
    },
  }

  const dropTargetProps = (targetFolder: string) =>
    buildDropTargetProps(targetFolder, renameNote, renameFolder)

  return {
    menuPos,
    drawerOpen,
    renaming,
    showDelete,
    showMove,
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

  const dropTargetProps = (targetFolder: string) =>
    buildDropTargetProps(targetFolder, renameNote, renameFolder)

  return { dropTargetProps }
}

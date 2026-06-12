import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router'
import { useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  type Folder,
  FOLDER_NOTES_STALE_MS,
  type Note,
  type NoteSummary,
  useFolders,
  useFolderNotes,
  useBatchDeleteNotes,
  useBatchMoveNotes,
  useBatchDeleteFolders,
  useBatchMoveFolders,
  useRenameNote,
  useRenameFolder,
  useDuplicateNote,
} from '../api/queries'
import { api } from '../api/client'
import { useActiveVaultId } from '../api/active-vault'
import { useFolderTreeState } from '../layout/folder-tree-context'
import { useEngramTree } from './tree/use-engram-tree'
import { TreeRowVirtualized } from './tree/tree-row-virtualized'
import { SelectionBar } from './tree/selection-bar'
import { parseItemId } from './tree/types'
import type { LoaderItem } from './tree/loader'
import { DeleteConfirm } from './tree-actions/delete-confirm'
import { MoveDialog } from './tree-actions/move-dialog'
import { ContextMenu } from './tree-actions/context-menu'
import { ActionDrawer } from './tree-actions/action-drawer'
import { actionsFor, type ActionId } from './tree-actions/action-list'
import { nextCopyName } from './tree-actions/duplicate'

// Row shapes that <DeleteConfirm> and <MoveDialog> accept.
type DeleteRow =
  | { kind: 'file'; path: string }
  | { kind: 'folder'; path: string; childCount: number }
type MoveRow =
  | { kind: 'file'; path: string }
  | { kind: 'folder'; path: string }

// Module-level stable empty array — passing `folders ?? []` creates a new
// reference each render while the query is loading, which spins up an
// infinite re-render loop in useEngramTree's rebuildTree effect.
const EMPTY_FOLDERS: Folder[] = []

type DialogState =
  | { kind: 'none' }
  | { kind: 'delete'; nodes: DeleteRow[]; itemIds: string[] }
  | { kind: 'move'; nodes: MoveRow[]; itemIds: string[] }
  | { kind: 'context'; itemId: string; position: { x: number; y: number } }
  | { kind: 'drawer'; itemId: string }

export default function FolderTree() {
  const { data: folders, isLoading, isError } = useFolders()
  // Root notes still come via the legacy path-keyed endpoint — the by-id
  // hook requires a non-null folderId. The loader stitches these into
  // the tree under ROOT.
  const { data: rootNotes = [] } = useFolderNotes('', { enabled: true })
  const { sort } = useFolderTreeState()
  const vaultId = useActiveVaultId()
  const qc = useQueryClient()
  const params = useParams()
  const selectedNoteId = params.id ?? null

  const scrollRef = useRef<HTMLDivElement | null>(null)
  const [dialog, setDialog] = useState<DialogState>({ kind: 'none' })

  const batchDeleteNotes = useBatchDeleteNotes()
  const batchMoveNotes = useBatchMoveNotes()
  const batchDeleteFolders = useBatchDeleteFolders()
  const batchMoveFolders = useBatchMoveFolders()
  const renameNote = useRenameNote()
  const renameFolder = useRenameFolder()
  const duplicateNote = useDuplicateNote()

  // Rename handler — TreeRow already wires HT's renaming state. HT calls
  // back with the new leaf-name; we rebuild the new full path from the
  // existing item path's folder + new leaf name.
  const onRenameCommit = (itemId: string, newName: string) => {
    const p = parseItemId(itemId)
    if (p.kind === 'note') {
      const item = qc.getQueryCache().findAll({ queryKey: ['folder-notes-by-id', vaultId] })
        .flatMap((q) => (q.state.data as Array<{ id: string; path: string }> | undefined) ?? [])
        .find((n) => n.id === p.id)
      if (!item) return
      const parts = item.path.split('/')
      parts[parts.length - 1] = newName
      const new_path = parts.join('/')
      renameNote.mutateAsync({ old_path: item.path, new_path }).catch(() => toast.error('Rename failed'))
    } else if (p.kind === 'folder') {
      const folder = folders?.find((f) => f.id === p.id)
      if (!folder) return
      const parts = folder.name.split('/')
      parts[parts.length - 1] = newName
      const new_path = parts.join('/')
      renameFolder.mutateAsync({ old_path: folder.name, new_path }).catch(() => toast.error('Rename failed'))
    }
  }

  // Drag-and-drop move — partition sources by kind, dispatch to the
  // matching batch hook. Drop target must be a folder.
  const onMove = (sourceIds: string[], targetItemId: string) => {
    const target = parseItemId(targetItemId)
    if (target.kind !== 'folder') return
    const parsed = sourceIds.map(parseItemId)
    const noteIds = parsed.filter((p) => p.kind === 'note').map((p) => (p as { id: string }).id)
    const folderIds = parsed.filter((p) => p.kind === 'folder').map((p) => (p as { id: string }).id)
    if (noteIds.length) batchMoveNotes.mutate({ ids: noteIds, target_folder_id: target.id })
    if (folderIds.length) batchMoveFolders.mutate({ ids: folderIds, target_parent_id: target.id })
  }

  // The loader fires this on cache-miss when a folder is expanded. Mirrors
  // the queryFn inside `useFolderNotesById` so react-query treats both as
  // the same query (cache key + fetcher shape).
  const fetchFolderNotes = useCallback(
    (folderId: string) =>
      api
        .get<{ notes: NoteSummary[] }>(`/folders/by-id/${folderId}/notes`)
        .then((r) => r.notes),
    [],
  )

  // Prefetch on hover — by the time the user clicks, the notes are usually
  // already cached, so expansion is instant. Uses the same key as the loader
  // so we don't fetch twice if the user clicks before the hover resolves.
  const prefetchFolderNotes = useCallback(
    (folderId: string) => {
      void qc.prefetchQuery({
        queryKey: ['folder-notes-by-id', vaultId, folderId],
        queryFn: () => fetchFolderNotes(folderId),
        staleTime: FOLDER_NOTES_STALE_MS,
      })
    },
    [qc, vaultId, fetchFolderNotes],
  )

  // Bulk prefetch every folder's notes once after `useFolders` lands. Trades
  // a small burst of parallel requests at startup for zero-latency folder
  // expansion thereafter. Skipped on every render — gated on folders length
  // becoming non-zero — and `staleTime` keeps it idempotent on remount.
  const bulkPrefetchedRef = useRef(false)
  useEffect(() => {
    if (bulkPrefetchedRef.current) return
    if (!folders || folders.length === 0) return
    bulkPrefetchedRef.current = true
    for (const f of folders) prefetchFolderNotes(f.id)
  }, [folders, prefetchFolderNotes])

  const { tree, virtualizer, items } = useEngramTree({
    folders: folders ?? EMPTY_FOLDERS,
    rootNotes,
    qc,
    vaultId: vaultId ?? '',
    sort,
    scrollParentRef: scrollRef,
    onRenameCommit,
    onMove,
    fetchFolderNotes,
  })

  // Auto-expand the chain leading to the active note so users can see
  // where they are after navigation. Mirrors the old recursive
  // `containsSelected` behaviour but driven by HT's expand API.
  useEffect(() => {
    if (selectedNoteId == null || !folders) return
    const note = qc.getQueryData<Note>(['note', vaultId, selectedNoteId])
    if (!note?.folder) return
    const segments = note.folder.split('/')
    for (let i = 1; i <= segments.length; i++) {
      const path = segments.slice(0, i).join('/')
      const folder = folders.find((f) => f.name === path)
      if (folder) {
        const instance = tree.getItemInstance(`f:${folder.id}`)
        if (instance && !instance.isExpanded()) instance.expand()
      }
    }
  }, [selectedNoteId, folders, vaultId, qc, tree])

  // Selection helpers — drive SelectionBar + bulk action handlers.
  const selectedItems = tree.getSelectedItems()
  const selectionCount = selectedItems.length

  const itemsToRows = useMemo(
    () => (kind: 'delete' | 'move'): DeleteRow[] | MoveRow[] => {
      const rows: Array<DeleteRow & MoveRow> = []
      for (const inst of selectedItems) {
        const data = inst.getItemData() as LoaderItem | undefined
        if (!data) continue
        const item = data.item
        if (item.kind === 'note') {
          rows.push({ kind: 'file', path: item.path, childCount: 0 } as DeleteRow & MoveRow)
        } else {
          const folder = folders?.find((f) => f.id === item.id)
          const direct = folder?.count ?? 0
          const descendants = folders
            ?.filter((f) => folder && f.name.startsWith(`${folder.name}/`))
            .reduce((sum, f) => sum + f.count, 0) ?? 0
          rows.push({ kind: 'folder', path: item.path, childCount: direct + descendants } as DeleteRow & MoveRow)
        }
      }
      return kind === 'delete' ? (rows as DeleteRow[]) : (rows as MoveRow[])
    },
    [selectedItems, folders],
  )

  // Resolve a single item id → the row shape DeleteConfirm / MoveDialog accept.
  function rowsFor(itemId: string, mode: 'delete' | 'move'): DeleteRow[] | MoveRow[] {
    const p = parseItemId(itemId)
    if (p.kind === 'note') {
      const note = lookupNote(p.id)
      if (!note) return []
      return mode === 'delete'
        ? [{ kind: 'file', path: note.path }]
        : [{ kind: 'file', path: note.path }]
    }
    if (p.kind === 'folder') {
      const folder = folders?.find((f) => f.id === p.id)
      if (!folder) return []
      const direct = folder.count
      const descendants =
        folders?.filter((f) => f.name.startsWith(`${folder.name}/`)).reduce((sum, f) => sum + f.count, 0) ?? 0
      return mode === 'delete'
        ? [{ kind: 'folder', path: folder.name, childCount: direct + descendants }]
        : [{ kind: 'folder', path: folder.name }]
    }
    return []
  }

  function lookupNote(id: string): { id: string; path: string; title?: string } | undefined {
    const cached = qc
      .getQueryCache()
      .findAll({ queryKey: ['folder-notes-by-id', vaultId] })
      .flatMap((q) => (q.state.data as Array<{ id: string; path: string; title?: string }> | undefined) ?? [])
      .find((n) => n.id === id)
    if (cached) return cached
    return rootNotes.find((n) => n.id === id)
  }

  function kindOf(itemId: string): 'file' | 'folder' {
    const p = parseItemId(itemId)
    return p.kind === 'folder' ? 'folder' : 'file'
  }

  function titleForItem(itemId: string): string {
    const p = parseItemId(itemId)
    if (p.kind === 'folder') {
      const f = folders?.find((x) => x.id === p.id)
      return f ? f.name.split('/').pop() ?? f.name : 'Folder'
    }
    if (p.kind === 'note') {
      const n = lookupNote(p.id)
      return n?.title || n?.path.split('/').pop() || 'Note'
    }
    return ''
  }

  function openDelete(itemIds?: string[]) {
    const ids = itemIds ?? selectedItems.map((inst) => inst.getId())
    const nodes = itemIds
      ? (itemIds.flatMap((id) => rowsFor(id, 'delete')) as DeleteRow[])
      : (itemsToRows('delete') as DeleteRow[])
    setDialog({ kind: 'delete', nodes, itemIds: ids })
  }

  function openMove(itemIds?: string[]) {
    const ids = itemIds ?? selectedItems.map((inst) => inst.getId())
    const nodes = itemIds
      ? (itemIds.flatMap((id) => rowsFor(id, 'move')) as MoveRow[])
      : (itemsToRows('move') as MoveRow[])
    setDialog({ kind: 'move', nodes, itemIds: ids })
  }

  function handleContextMenu(itemId: string, x: number, y: number) {
    setDialog({ kind: 'context', itemId, position: { x, y } })
  }

  function handleLongPress(itemId: string) {
    setDialog({ kind: 'drawer', itemId })
  }

  function handleActionPick(actionId: ActionId, itemId: string) {
    switch (actionId) {
      case 'rename': {
        const instance = tree.getItemInstance(itemId)
        if (instance) instance.startRenaming()
        break
      }
      case 'delete':
        openDelete([itemId])
        break
      case 'move':
        openMove([itemId])
        break
      case 'duplicate': {
        const p = parseItemId(itemId)
        if (p.kind !== 'note') break
        const note = lookupNote(p.id)
        if (!note) break
        // No reliable sibling-name set on hand — pass an empty Set and let
        // the backend reject if collision happens; the toast surfaces it.
        const new_path = nextCopyName(note.path, new Set<string>())
        duplicateNote
          .mutateAsync({ src_path: note.path, new_path })
          .then(() => toast.success('Duplicated'))
          .catch(() => toast.error('Duplicate failed'))
        break
      }
      case 'copy-wikilink': {
        const p = parseItemId(itemId)
        if (p.kind !== 'note') break
        const note = lookupNote(p.id)
        if (!note) break
        const label = note.title || note.path.split('/').pop() || note.path
        navigator.clipboard
          .writeText(`[[${label}]]`)
          .then(() => toast.success('Copied wikilink'))
          .catch(() => toast.error('Copy failed'))
        break
      }
    }
  }

  function partition(itemIds: string[]): { noteIds: string[]; folderIds: string[] } {
    const noteIds: string[] = []
    const folderIds: string[] = []
    for (const id of itemIds) {
      const p = parseItemId(id)
      if (p.kind === 'note') noteIds.push(p.id)
      else if (p.kind === 'folder') folderIds.push(p.id)
    }
    return { noteIds, folderIds }
  }

  function commitDelete() {
    if (dialog.kind !== 'delete') return
    const { noteIds, folderIds } = partition(dialog.itemIds)
    if (noteIds.length) batchDeleteNotes.mutate({ ids: noteIds })
    if (folderIds.length) batchDeleteFolders.mutate({ ids: folderIds })
    tree.setSelectedItems([])
    setDialog({ kind: 'none' })
  }

  function commitMove(targetFolderName: string) {
    if (dialog.kind !== 'move') return
    const target = folders?.find((f) => f.name === targetFolderName)
    if (!target) {
      setDialog({ kind: 'none' })
      return
    }
    const { noteIds, folderIds } = partition(dialog.itemIds)
    if (noteIds.length) batchMoveNotes.mutate({ ids: noteIds, target_folder_id: target.id })
    if (folderIds.length) batchMoveFolders.mutate({ ids: folderIds, target_parent_id: target.id })
    tree.setSelectedItems([])
    setDialog({ kind: 'none' })
  }

  if (isLoading) {
    return (
      <p data-testid="folder-tree-root" className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">
        Loading…
      </p>
    )
  }
  if (isError) {
    return (
      <p data-testid="folder-tree-root" className="px-3 py-2 text-xs text-red-600 dark:text-red-400">
        Failed to load folders.
      </p>
    )
  }
  // Empty only when there are neither folders nor root-level notes. A vault
  // with root notes but no folders (e.g. a freshly created "Untitled" at root)
  // must still render the tree — the loader stitches rootNotes under ROOT.
  if (!folders || (folders.length === 0 && rootNotes.length === 0)) {
    return (
      <p data-testid="folder-tree-root" className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">
        No notes yet.
      </p>
    )
  }

  // Register the scroll container with BOTH the virtualizer (scrollRef) and
  // headless-tree (so getDragLineStyle's coordinates have the right origin).
  // HT's ref is `tree.registerElement`, which is idempotent, so merging is safe.
  const containerProps = tree.getContainerProps('Files')
  const setContainerEl = useCallback(
    (el: HTMLDivElement | null) => {
      scrollRef.current = el
      const htRef = (containerProps as { ref?: (e: HTMLElement | null) => void }).ref
      htRef?.(el)
    },
    [containerProps],
  )

  return (
    <>
      <nav
        {...containerProps}
        ref={setContainerEl}
        data-testid="folder-tree-root"
        className="relative flex-1 overflow-auto py-2 text-base"
      >
        <div style={{ height: virtualizer.getTotalSize(), position: 'relative' }}>
          {virtualizer.getVirtualItems().map((v) => (
            <TreeRowVirtualized
              key={items[v.index]?.getId() ?? v.index}
              virtualItem={v}
              items={items}
              onContextMenu={handleContextMenu}
              onLongPress={handleLongPress}
              onFolderHover={prefetchFolderNotes}
            />
          ))}
        </div>
        <div
          aria-hidden
          style={tree.getDragLineStyle()}
          className="z-10 h-0.5 rounded bg-blue-500"
        />
      </nav>

      <SelectionBar
        count={selectionCount}
        onMove={() => openMove()}
        onDelete={() => openDelete()}
        onCancel={() => tree.setSelectedItems([])}
      />

      {dialog.kind === 'delete' && (
        <DeleteConfirm
          nodes={dialog.nodes}
          onConfirm={commitDelete}
          onCancel={() => setDialog({ kind: 'none' })}
        />
      )}
      {dialog.kind === 'move' && (
        <MoveDialog
          nodes={dialog.nodes}
          folders={folders.map((f) => ({ name: f.name }))}
          onPick={commitMove}
          onCancel={() => setDialog({ kind: 'none' })}
        />
      )}
      {dialog.kind === 'context' && (
        <ContextMenu
          actions={actionsFor({ kind: kindOf(dialog.itemId) })}
          position={dialog.position}
          onPick={(actionId) => handleActionPick(actionId, dialog.itemId)}
          onClose={() => setDialog({ kind: 'none' })}
        />
      )}
      {dialog.kind === 'drawer' && (
        <ActionDrawer
          title={titleForItem(dialog.itemId)}
          actions={actionsFor({ kind: kindOf(dialog.itemId) })}
          onPick={(actionId) => handleActionPick(actionId, dialog.itemId)}
          onClose={() => setDialog({ kind: 'none' })}
          onSelectMore={() => {
            tree.setSelectedItems([dialog.itemId])
            setDialog({ kind: 'none' })
          }}
        />
      )}
    </>
  )
}

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router'
import { useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  type AttachmentSummary,
  type Folder,
  FOLDER_NOTES_STALE_MS,
  fetchNotesForFolderId,
  type Note,
  ROOT_FOLDER_ID,
  useAttachments,
  useFolders,
  useFolderNotesById,
  useBatchDeleteNotes,
  useBatchMoveNotes,
  useBatchDeleteFolders,
  useBatchMoveFolders,
  useRenameNote,
  useRenameFolder,
  useDuplicateNote,
} from '../api/queries'
import { synthesizeFolders } from './tree/synthesize-folders'
import { useActiveVaultId } from '../api/active-vault'
import { useFolderTreeState } from '../layout/folder-tree-context'
import { useEngramTree } from './tree/use-engram-tree'
import { TreeRowVirtualized } from './tree/tree-row-virtualized'
import { parseItemId } from './tree/types'
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

// Module-level stable empty arrays — passing `folders ?? []` / `attachments ?? []`
// creates a new reference each render while the query is loading, which spins
// up an infinite re-render loop in useEngramTree's rebuildTree effect.
const EMPTY_FOLDERS: Folder[] = []
const EMPTY_ATTACHMENTS: AttachmentSummary[] = []

type DialogState =
  | { kind: 'none' }
  | { kind: 'delete'; nodes: DeleteRow[]; itemIds: string[] }
  | { kind: 'move'; nodes: MoveRow[]; itemIds: string[] }
  | { kind: 'context'; itemId: string; position: { x: number; y: number } }
  | { kind: 'drawer'; itemId: string }

export default function FolderTree() {
  const { data: folders, isLoading, isError } = useFolders()
  // Root notes share the one id-keyed cache under the ROOT_FOLDER_ID sentinel
  // (its fetcher hits the path-keyed list endpoint, since the by-id endpoint
  // needs a real folder id). Subscribing here gives root an observer so
  // invalidations refetch it; the loader stitches the rows under ROOT.
  const { data: rootNotes = [] } = useFolderNotesById(ROOT_FOLDER_ID)
  const { data: attachments = EMPTY_ATTACHMENTS } = useAttachments()
  const allFolders = useMemo(
    () => synthesizeFolders(folders ?? EMPTY_FOLDERS, attachments),
    [folders, attachments],
  )
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
  // matching batch hook. Drop target must be a folder or the vault root.
  const onMove = (sourceIds: string[], targetItemId: string) => {
    const target = parseItemId(targetItemId)
    if (target.kind !== 'folder' && target.kind !== 'root') return
    const parsed = sourceIds.map(parseItemId)
    const noteIds = parsed.filter((p) => p.kind === 'note').map((p) => (p as { id: string }).id)
    const folderIds = parsed.filter((p) => p.kind === 'folder').map((p) => (p as { id: string }).id)
    // 'root' is the backend sentinel for the vault root; a folder target uses
    // its marker id. Note→root has no optimistic patch (root notes live under a
    // different cache key than the by-id folder lists), so a moved note briefly
    // disappears until useBatchMoveNotes' onSuccess invalidation + the
    // count-keyed rebuildTree reconcile it at root — an accepted trade-off.
    const dest = target.kind === 'root' ? 'root' : target.id
    if (noteIds.length) batchMoveNotes.mutate({ ids: noteIds, target_folder_id: dest })
    if (folderIds.length) batchMoveFolders.mutate({ ids: folderIds, target_parent_id: dest })
  }

  // The loader fires this on cache-miss when a folder is expanded. Shares the
  // single fetcher with `useFolderNotesById` so react-query treats both as the
  // same query (cache key + fetcher shape) — and so a 'root' id routes to the
  // path-keyed list endpoint instead of the non-existent by-id/root route.
  const fetchFolderNotes = useCallback(
    (folderId: string) => fetchNotesForFolderId(folderId),
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
    folders: allFolders,
    attachments,
    qc,
    vaultId: vaultId ?? '',
    sort,
    scrollParentRef: scrollRef,
    onRenameCommit,
    onMove,
    fetchFolderNotes,
  })

  // Register the scroll container with BOTH the virtualizer (scrollRef) and
  // headless-tree, whose getContainerProps supplies the empty-space drop handler
  // (drops not on a row resolve to the vault root). Depends only on the stable
  // `tree` instance — avoids ref churn from the new-object-every-render props.
  const containerProps = tree.getContainerProps('Files')
  const setContainerEl = useCallback(
    (el: HTMLDivElement | null) => {
      scrollRef.current = el
      tree.registerElement(el)
    },
    [tree],
  )

  const [rootDragOver, setRootDragOver] = useState(false)
  const onContainerDragOver = (e: React.DragEvent) => {
    ;(containerProps.onDragOver as ((ev: React.DragEvent) => void) | undefined)?.(e)
    setRootDragOver(true)
  }
  const onContainerDragLeave = () => setRootDragOver(false)
  const onContainerDrop = (e: React.DragEvent) => {
    setRootDragOver(false)
    ;(containerProps.onDrop as ((ev: React.DragEvent) => void) | undefined)?.(e)
  }

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

  function openDelete(itemIds: string[]) {
    const nodes = itemIds.flatMap((id) => rowsFor(id, 'delete')) as DeleteRow[]
    setDialog({ kind: 'delete', nodes, itemIds })
  }

  function openMove(itemIds: string[]) {
    const nodes = itemIds.flatMap((id) => rowsFor(id, 'move')) as MoveRow[]
    setDialog({ kind: 'move', nodes, itemIds })
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
  if (!folders || (allFolders.length === 0 && rootNotes.length === 0 && attachments.length === 0)) {
    return (
      <p data-testid="folder-tree-root" className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">
        No notes yet.
      </p>
    )
  }

  return (
    <>
      <nav
        {...containerProps}
        ref={setContainerEl}
        onDragOver={onContainerDragOver}
        onDragLeave={onContainerDragLeave}
        onDrop={onContainerDrop}
        data-testid="folder-tree-root"
        data-tour="folder-tree"
        className={`relative min-h-0 flex-1 overflow-auto py-2 text-base ${
          rootDragOver ? 'ring-1 ring-inset ring-blue-400 bg-blue-50/40 dark:bg-blue-950/30' : ''
        }`}
      >
        {/* minHeight ensures blank, droppable space below the rows even for a
            short tree, so there's always a place to drop "to root". */}
        <div style={{ height: virtualizer.getTotalSize(), minHeight: '100%', position: 'relative' }}>
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
      </nav>

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
        />
      )}
    </>
  )
}

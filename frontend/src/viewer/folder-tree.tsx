import { useEffect, useMemo, useRef, useState } from 'react'
import { useParams } from 'react-router'
import { useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import {
  type Note,
  useFolders,
  useFolderNotes,
  useBatchDeleteNotes,
  useBatchMoveNotes,
  useBatchDeleteFolders,
  useBatchMoveFolders,
  useRenameNote,
  useRenameFolder,
} from '../api/queries'
import { useActiveVaultId } from '../api/active-vault'
import { useFolderTreeState } from '../layout/folder-tree-context'
import { useEngramTree } from './tree/use-engram-tree'
import { TreeRowVirtualized } from './tree/tree-row-virtualized'
import { SelectionBar } from './tree/selection-bar'
import { parseItemId } from './tree/types'
import type { LoaderItem } from './tree/loader'
import { DeleteConfirm } from './tree-actions/delete-confirm'
import { MoveDialog } from './tree-actions/move-dialog'

// Row shapes that <DeleteConfirm> and <MoveDialog> accept.
type DeleteRow =
  | { kind: 'file'; path: string }
  | { kind: 'folder'; path: string; childCount: number }
type MoveRow =
  | { kind: 'file'; path: string }
  | { kind: 'folder'; path: string }

type DialogState =
  | { kind: 'none' }
  | { kind: 'delete'; nodes: DeleteRow[] }
  | { kind: 'move'; nodes: MoveRow[] }

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
  const selectedNoteId = params.id ? Number(params.id) : null

  const scrollRef = useRef<HTMLDivElement | null>(null)
  const [dialog, setDialog] = useState<DialogState>({ kind: 'none' })

  const batchDeleteNotes = useBatchDeleteNotes()
  const batchMoveNotes = useBatchMoveNotes()
  const batchDeleteFolders = useBatchDeleteFolders()
  const batchMoveFolders = useBatchMoveFolders()
  const renameNote = useRenameNote()
  const renameFolder = useRenameFolder()

  // Rename handler — TreeRow already wires HT's renaming state. HT calls
  // back with the new leaf-name; we rebuild the new full path from the
  // existing item path's folder + new leaf name.
  const onRenameCommit = (itemId: string, newName: string) => {
    const p = parseItemId(itemId)
    if (p.kind === 'note') {
      const item = qc.getQueryCache().findAll({ queryKey: ['folder-notes-by-id', vaultId] })
        .flatMap((q) => (q.state.data as Array<{ id: number; path: string }> | undefined) ?? [])
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
    const noteIds = parsed.filter((p) => p.kind === 'note').map((p) => (p as { id: number }).id)
    const folderIds = parsed.filter((p) => p.kind === 'folder').map((p) => (p as { id: number }).id)
    if (noteIds.length) batchMoveNotes.mutate({ ids: noteIds, target_folder_id: target.id })
    if (folderIds.length) batchMoveFolders.mutate({ ids: folderIds, target_parent_id: target.id })
  }

  const { tree, virtualizer, items } = useEngramTree({
    folders: folders ?? [],
    rootNotes,
    qc,
    vaultId: vaultId ?? '',
    sort,
    scrollParentRef: scrollRef,
    onRenameCommit,
    onMove,
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

  function openDelete() {
    setDialog({ kind: 'delete', nodes: itemsToRows('delete') as DeleteRow[] })
  }

  function openMove() {
    setDialog({ kind: 'move', nodes: itemsToRows('move') as MoveRow[] })
  }

  function commitDelete() {
    const noteIds: number[] = []
    const folderIds: number[] = []
    for (const inst of selectedItems) {
      const data = inst.getItemData() as LoaderItem | undefined
      if (!data) continue
      const item = data.item
      if (item.kind === 'note') noteIds.push(item.id)
      else folderIds.push(item.id)
    }
    if (noteIds.length) batchDeleteNotes.mutate({ ids: noteIds })
    if (folderIds.length) batchDeleteFolders.mutate({ ids: folderIds })
    tree.setSelectedItems([])
    setDialog({ kind: 'none' })
  }

  function commitMove(targetFolderName: string) {
    const target = folders?.find((f) => f.name === targetFolderName)
    if (!target) {
      setDialog({ kind: 'none' })
      return
    }
    const noteIds: number[] = []
    const folderIds: number[] = []
    for (const inst of selectedItems) {
      const data = inst.getItemData() as LoaderItem | undefined
      if (!data) continue
      const item = data.item
      if (item.kind === 'note') noteIds.push(item.id)
      else folderIds.push(item.id)
    }
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
  if (!folders || folders.length === 0) {
    return (
      <p data-testid="folder-tree-root" className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">
        No notes yet.
      </p>
    )
  }

  return (
    <>
      <nav
        ref={scrollRef}
        role="tree"
        aria-label="Files"
        data-testid="folder-tree-root"
        className="flex-1 overflow-auto py-2 text-base"
      >
        <div style={{ height: virtualizer.getTotalSize(), position: 'relative' }}>
          {virtualizer.getVirtualItems().map((v) => (
            <TreeRowVirtualized
              key={items[v.index]?.getId() ?? v.index}
              virtualItem={v}
              items={items}
            />
          ))}
        </div>
      </nav>

      <SelectionBar
        count={selectionCount}
        onMove={openMove}
        onDelete={openDelete}
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
    </>
  )
}

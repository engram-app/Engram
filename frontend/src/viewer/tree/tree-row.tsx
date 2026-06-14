import type React from 'react'
import { ChevronRight } from 'lucide-react'
import { Link } from 'react-router'
import type { ItemInstance } from '@headless-tree/core'
import type { LoaderItem } from './loader'
import type { TreeItem } from './types'
import { RenameInput } from '../tree-actions/rename-input'
import { useLongPress } from '../tree-actions/use-long-press'

interface Props {
  instance: ItemInstance<LoaderItem>
  onContextMenu?: (itemId: string, x: number, y: number) => void
  onLongPress?: (itemId: string) => void
  onFolderHover?: (folderId: string) => void
}

export function TreeRow({ instance, onContextMenu, onLongPress, onFolderHover }: Props) {
  const itemId = instance.getId()
  const longPressHandlers = useLongPress({
    onLongPress: () => onLongPress?.(itemId),
  })
  const longPressProps = onLongPress ? longPressHandlers : undefined
  const contextMenuHandler = onContextMenu
    ? (e: React.MouseEvent) => {
        e.preventDefault()
        onContextMenu(itemId, e.clientX, e.clientY)
      }
    : undefined

  const data = instance.getItemData()
  const item = data.item
  const depth = instance.getItemMeta()?.level ?? 0
  const folderPad = depth * 12 + 4
  const notePad = folderPad + 20 // align note label under folder name (chevron 16px + gap 4px)

  if (instance.isRenaming()) {
    const tree = instance.getTree()
    return (
      <div
        className="flex items-center gap-1 py-0.5 pl-1 pr-3"
        style={{ paddingLeft: `${item.kind === 'folder' ? folderPad : notePad}px` }}
      >
        <RenameInput
          initial={leafName(item)}
          kind={item.kind === 'folder' ? 'folder' : 'file'}
          onCommit={(value) => {
            const treeWithRename = tree as unknown as {
              completeRenaming: () => void
              getRenamingValue: () => string
              applySubStateUpdate?: (k: 'renamingValue', updater: () => string) => void
              setState?: (updater: (s: { renamingValue?: string }) => { renamingValue?: string }) => void
            }
            // RenameInput owns the input value; sync it onto HT renaming state before completing.
            // HT exposes renamingValue via state — bypass cleanly by writing through setState if present.
            treeWithRename.setState?.((s) => ({ ...s, renamingValue: value }))
            treeWithRename.completeRenaming()
          }}
          onCancel={() => tree.abortRenaming()}
        />
      </div>
    )
  }

  if (item.kind === 'folder') {
    const hoverPrefetch = onFolderHover
      ? () => onFolderHover(item.id)
      : undefined
    return (
      <button
        type="button"
        {...instance.getProps()}
        {...longPressProps}
        onContextMenu={contextMenuHandler}
        onPointerEnter={hoverPrefetch}
        onFocus={hoverPrefetch}
        aria-expanded={instance.isExpanded()}
        aria-selected={instance.isSelected()}
        className={rowClass(instance)}
        style={{ paddingLeft: `${folderPad}px` }}
      >
        <Chevron open={instance.isExpanded()} />
        <span className="min-w-0 flex-1 truncate">{item.name}</span>
      </button>
    )
  }

  const htProps = instance.getProps()
  const handleNoteDragStart = (e: React.DragEvent) => {
    // Run HT's own drag init first (it tracks the drag via internal state).
    ;(htProps.onDragStart as ((ev: React.DragEvent) => void) | undefined)?.(e)
    // Then strip the <a href> link payload the browser auto-adds, so Chrome/Edge
    // don't offer a split view / "open in new tab" while dragging the note within
    // the tree. HT's move reads internal state, not dataTransfer, so this is safe.
    e.dataTransfer.clearData('text/uri-list')
    e.dataTransfer.clearData('text/plain')
    e.dataTransfer.clearData('text/html')
  }

  return (
    <Link
      to={`/note/${item.id}`}
      {...htProps}
      {...longPressProps}
      onContextMenu={contextMenuHandler}
      onDragStart={handleNoteDragStart}
      aria-selected={instance.isSelected()}
      className={rowClass(instance)}
      style={{ paddingLeft: `${notePad}px` }}
    >
      <span className="min-w-0 flex-1 truncate">{noteLabel(item)}</span>
      {item.ext && item.ext !== 'md' && (
        <span className="shrink-0 text-xs uppercase text-gray-400 dark:text-gray-500">{item.ext}</span>
      )}
    </Link>
  )
}

function rowClass(instance: ItemInstance<LoaderItem>): string {
  // `isDragTarget` is provided by dragAndDropFeature; guard in case the row is
  // rendered without it (tests).
  const dragOver =
    (instance as { isDragTarget?: () => boolean }).isDragTarget?.() ?? false
  return [
    // w-full so the folder <button> stretches like the note <a> (form controls
    // shrink to content by default) — gives both the same full-width hover hit.
    'flex w-full items-center gap-1 rounded py-0.5 pl-1 pr-3 text-left',
    instance.isSelected()
      ? 'bg-blue-50 dark:bg-blue-950 font-medium text-blue-700 dark:text-blue-300'
      : 'text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800',
    dragOver ? 'ring-1 ring-inset ring-blue-400 bg-blue-100/60 dark:bg-blue-900/40' : '',
  ].join(' ')
}

function leafName(item: TreeItem): string {
  if (item.kind === 'folder') return item.name
  return item.path.split('/').pop() ?? item.path
}

function noteLabel(item: Extract<TreeItem, { kind: 'note' }>): string {
  return item.title || item.path.split('/').pop() || item.path
}

function Chevron({ open }: { open: boolean }) {
  return (
    <ChevronRight
      aria-hidden="true"
      className={`h-4 w-4 shrink-0 text-gray-400 dark:text-gray-500 transition-transform ${
        open ? 'rotate-90' : ''
      }`}
    />
  )
}

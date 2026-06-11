import type React from 'react'
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
  const notePad = folderPad + 12 // align note label past where a folder chevron would sit

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
        <FolderIcon open={instance.isExpanded()} />
        <span className="min-w-0 flex-1 truncate">{item.name}</span>
      </button>
    )
  }

  return (
    <Link
      to={`/note/${item.id}`}
      {...instance.getProps()}
      {...longPressProps}
      onContextMenu={contextMenuHandler}
      aria-selected={instance.isSelected()}
      className={rowClass(instance)}
      style={{ paddingLeft: `${notePad}px` }}
    >
      <FileIcon />
      <span className="min-w-0 flex-1 truncate">{noteLabel(item)}</span>
      {item.ext && item.ext !== 'md' && (
        <span className="shrink-0 text-xs uppercase text-gray-400 dark:text-gray-500">{item.ext}</span>
      )}
    </Link>
  )
}

function rowClass(instance: ItemInstance<LoaderItem>): string {
  return [
    'flex items-center gap-1 rounded py-0.5 pl-1 pr-3 text-left',
    instance.isSelected()
      ? 'bg-blue-50 dark:bg-blue-950 font-medium text-blue-700 dark:text-blue-300'
      : 'text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800',
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
    <span
      aria-hidden="true"
      className={`shrink-0 text-[10px] text-gray-400 dark:text-gray-500 transition-transform ${
        open ? 'rotate-90' : ''
      }`}
    >
      ▶
    </span>
  )
}

function FolderIcon({ open }: { open: boolean }) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 16 16"
      className="h-3.5 w-3.5 shrink-0 text-gray-500 dark:text-gray-400"
      fill="currentColor"
    >
      {open ? (
        <path d="M2 4a1 1 0 0 1 1-1h3.586a1 1 0 0 1 .707.293L8.707 4.6A1 1 0 0 0 9.414 5H13a1 1 0 0 1 1 1H2V4zm0 3h12.5a.5.5 0 0 1 .49.598l-1 5A.5.5 0 0 1 13.5 13h-11a.5.5 0 0 1-.49-.402l-1-5A.5.5 0 0 1 1.5 7H2z" />
      ) : (
        <path d="M2 4a1 1 0 0 1 1-1h3.586a1 1 0 0 1 .707.293L8.707 4.6A1 1 0 0 0 9.414 5H13a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V4z" />
      )}
    </svg>
  )
}

function FileIcon() {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 16 16"
      className="h-3.5 w-3.5 shrink-0 text-gray-400 dark:text-gray-500"
      fill="currentColor"
    >
      <path d="M4 1a1 1 0 0 0-1 1v12a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V5.414a1 1 0 0 0-.293-.707L9.293 1.293A1 1 0 0 0 8.586 1H4zm5 0v4a1 1 0 0 0 1 1h3" />
    </svg>
  )
}

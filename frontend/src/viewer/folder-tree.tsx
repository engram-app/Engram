import { useMemo, useRef, type KeyboardEvent } from 'react'
import { Link, useLocation } from 'react-router'
import { toast } from 'sonner'
import {
  type NoteSummary,
  useDuplicateNote,
  useFolders,
  useFolderNotes,
  type Folder,
} from '../api/queries'
import { ApiError } from '../api/client'
import { type SortKey, useFolderTreeState } from '../layout/folder-tree-context'
import { ActionDrawer } from './tree-actions/action-drawer'
import { actionsFor, type ActionId } from './tree-actions/action-list'
import { ContextMenu } from './tree-actions/context-menu'
import { DeleteConfirm } from './tree-actions/delete-confirm'
import { MoveDialog } from './tree-actions/move-dialog'
import { RenameInput } from './tree-actions/rename-input'
import { nextCopyName } from './tree-actions/duplicate'
import { useLongPress } from './tree-actions/use-long-press'
import { useTreeDrop, useTreeRowActions } from './tree-actions/use-tree-row-actions'

interface TreeNode {
  name: string
  fullPath: string
  children: TreeNode[]
}

function buildTree(folders: Folder[], sort: SortKey): TreeNode[] {
  const root: TreeNode[] = []

  for (const folder of folders) {
    if (!folder.name) continue // root files handled separately
    const segments = folder.name.split('/')
    let level = root

    for (let i = 0; i < segments.length; i++) {
      const seg = segments[i] ?? ''
      const fullPath = segments.slice(0, i + 1).join('/')

      let node = level.find((n) => n.name === seg)
      if (!node) {
        node = { name: seg, fullPath, children: [] }
        level.push(node)
      }
      level = node.children
    }
  }

  sortTree(root, sort)
  return root
}

function sortTree(nodes: TreeNode[], sort: SortKey) {
  // Folders always sort by name — modification time doesn't make sense for them.
  const dir = sort === 'name-desc' ? -1 : 1
  nodes.sort((a, b) => dir * a.name.localeCompare(b.name))
  for (const n of nodes) sortTree(n.children, sort)
}

function sortNotes(notes: NoteSummary[], sort: SortKey): NoteSummary[] {
  const sign = sort.endsWith('-desc') ? -1 : 1
  if (sort.startsWith('modified')) {
    return [...notes].sort((a, b) => sign * (Date.parse(a.updated_at) - Date.parse(b.updated_at)))
  }
  if (sort.startsWith('created')) {
    return [...notes].sort((a, b) => sign * (Date.parse(a.created_at) - Date.parse(b.created_at)))
  }
  return [...notes].sort((a, b) => sign * a.title.localeCompare(b.title))
}

export default function FolderTree() {
  const { data: folders, isLoading, isError } = useFolders()
  const { sort } = useFolderTreeState()
  const location = useLocation()
  const rootDrop = useTreeDrop()
  // Note routes: /note/<path>. Read from pathname directly because
  // useParams() in the parent layout doesn't expose the child route's
  // splat. The pathname segments are %-encoded, decode each before
  // joining so we can compare against raw note paths.
  const selectedNotePath = location.pathname.startsWith('/note/')
    ? decodePathFromRouter(location.pathname.slice('/note/'.length))
    : null

  if (isLoading) {
    return <p data-testid="folder-tree-root" className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">Loading…</p>
  }
  if (isError) {
    return <p data-testid="folder-tree-root" className="px-3 py-2 text-xs text-red-600 dark:text-red-400">Failed to load folders.</p>
  }
  if (!folders || folders.length === 0) {
    return <p data-testid="folder-tree-root" className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">No notes yet.</p>
  }

  const tree = buildTree(folders, sort)
  const hasRootFiles = folders.some((f) => f.name === '')

  return (
    <nav
      aria-label="Files"
      className="py-2 text-base"
      data-testid="folder-tree-root"
      {...rootDrop.dropTargetProps('')}
    >
      <ul role="list" className="space-y-1">
        {hasRootFiles && (
          <RootFiles selectedNotePath={selectedNotePath} folders={folders} />
        )}
        {tree.map((node) => (
          <FolderNode
            key={node.fullPath}
            node={node}
            depth={0}
            selectedNotePath={selectedNotePath}
            folders={folders}
          />
        ))}
      </ul>
    </nav>
  )
}

function RootFiles({
  selectedNotePath,
  folders,
}: {
  selectedNotePath: string | null
  folders: Folder[]
}) {
  const { data: notes } = useFolderNotes('', { enabled: true })
  const { sort } = useFolderTreeState()
  if (!notes || notes.length === 0) return null
  return (
    <>
      {sortNotes(notes, sort).map((note) => (
        <NoteLeaf
          key={note.path}
          note={note}
          depth={0}
          selectedNotePath={selectedNotePath}
          folders={folders}
          siblingNotes={notes}
        />
      ))}
    </>
  )
}

interface FolderNodeProps {
  node: TreeNode
  depth: number
  selectedNotePath: string | null
  folders: Folder[]
}

function FolderNode({ node, depth, selectedNotePath, folders }: FolderNodeProps) {
  const { isOpen: getIsOpen, toggle } = useFolderTreeState()
  // Force-open the chain leading to the active note so the user can always see
  // where they are. Side effect: "Collapse all" leaves the active-note chain
  // open, which matches Obsidian's behaviour — intentional, not a bug.
  const containsSelected = selectedNotePath?.startsWith(`${node.fullPath}/`) ?? false
  const isOpen = getIsOpen(node.fullPath) || containsSelected

  const rowActions = useTreeRowActions({ kind: 'folder', path: node.fullPath, label: node.name })
  const longPress = useLongPress({ onLongPress: () => rowActions.openDrawer() })

  // childCount for delete-confirm — count immediate children + nested-folder counts.
  // Using the `folders` list count gives us a sane number without an extra fetch.
  const childCount = useMemo(() => {
    const direct = folders.find((f) => f.name === node.fullPath)?.count ?? 0
    const descendants = folders
      .filter((f) => f.name.startsWith(`${node.fullPath}/`))
      .reduce((sum, f) => sum + f.count, 0)
    return direct + descendants
  }, [folders, node.fullPath])

  const buttonRef = useRef<HTMLButtonElement>(null)
  const onPick = (id: ActionId) => handlePickAction(id, rowActions, { kind: 'folder', label: node.name })

  const onKeyDown = (e: KeyboardEvent<HTMLButtonElement>) => {
    if (e.key === 'F2') {
      e.preventDefault()
      rowActions.startRename()
    } else if (e.key === 'Delete' || e.key === 'Backspace') {
      e.preventDefault()
      rowActions.startDelete()
    }
  }

  return (
    <li>
      {rowActions.renaming ? (
        <div
          className="flex w-full items-center gap-1 py-0.5 pl-1 pr-3"
          style={{ paddingLeft: `${depth * 12 + 4}px` }}
        >
          <RenameInput
            initial={node.name}
            kind="folder"
            onCommit={rowActions.commitRename}
            onCancel={rowActions.cancelRename}
          />
        </div>
      ) : (
        <button
          ref={buttonRef}
          type="button"
          onClick={() => toggle(node.fullPath)}
          onContextMenu={(e) => {
            e.preventDefault()
            rowActions.openContextMenu({ x: e.clientX, y: e.clientY })
          }}
          onKeyDown={onKeyDown}
          aria-expanded={isOpen}
          className="flex w-full items-center gap-1 rounded py-0.5 pl-1 pr-3 text-left text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800"
          style={{ paddingLeft: `${depth * 12 + 4}px` }}
          {...rowActions.dragSourceProps}
          {...rowActions.dropTargetProps(node.fullPath)}
          {...longPress}
        >
          <span
            className={`shrink-0 text-[10px] text-gray-400 dark:text-gray-500 transition-transform ${
              isOpen ? 'rotate-90' : ''
            }`}
            aria-hidden="true"
          >
            ▶
          </span>
          <FolderIcon open={isOpen} />
          <span className="min-w-0 flex-1 truncate">{node.name}</span>
        </button>
      )}

      {rowActions.menuPos && (
        <ContextMenu
          actions={actionsFor({ kind: 'folder' })}
          position={rowActions.menuPos}
          onPick={onPick}
          onClose={rowActions.closeMenu}
        />
      )}
      {rowActions.drawerOpen && (
        <ActionDrawer
          title={node.name}
          actions={actionsFor({ kind: 'folder' })}
          onPick={onPick}
          onClose={rowActions.closeDrawer}
        />
      )}
      {rowActions.showDelete && (
        <DeleteConfirm
          node={{ kind: 'folder', path: node.fullPath, childCount }}
          onConfirm={rowActions.confirmDelete}
          onCancel={rowActions.cancelDelete}
        />
      )}
      {rowActions.showMove && (
        <MoveDialog
          folders={folders.map((f) => ({ name: f.name }))}
          node={{ kind: 'folder', path: node.fullPath }}
          onPick={rowActions.commitMove}
          onCancel={rowActions.cancelMove}
        />
      )}

      {isOpen && (
        <ul role="list" className="space-y-1">
          {node.children.map((child) => (
            <FolderNode
              key={child.fullPath}
              node={child}
              depth={depth + 1}
              selectedNotePath={selectedNotePath}
              folders={folders}
            />
          ))}
          <FolderFiles
            folderPath={node.fullPath}
            depth={depth + 1}
            selectedNotePath={selectedNotePath}
            folders={folders}
          />
        </ul>
      )}
    </li>
  )
}

function FolderFiles({
  folderPath,
  depth,
  selectedNotePath,
  folders,
}: {
  folderPath: string
  depth: number
  selectedNotePath: string | null
  folders: Folder[]
}) {
  const { data: notes, isLoading } = useFolderNotes(folderPath, { enabled: true })
  const { sort } = useFolderTreeState()
  if (isLoading) {
    return (
      <li
        className="px-1 py-0.5 text-xs text-gray-400 dark:text-gray-500"
        style={{ paddingLeft: `${depth * 12 + 4}px` }}
      >
        …
      </li>
    )
  }
  if (!notes || notes.length === 0) return null
  return (
    <>
      {sortNotes(notes, sort).map((note) => (
        <NoteLeaf
          key={note.path}
          note={note}
          depth={depth}
          selectedNotePath={selectedNotePath}
          folders={folders}
          siblingNotes={notes}
        />
      ))}
    </>
  )
}

function NoteLeaf({
  note,
  depth,
  selectedNotePath,
  folders,
  siblingNotes,
}: {
  note: NoteSummary
  depth: number
  selectedNotePath: string | null
  folders: Folder[]
  siblingNotes: NoteSummary[]
}) {
  const isSelected = selectedNotePath === note.path
  const extension = nonMdExtension(note.path)
  const label = noteLabel(note)
  const fileName = note.path.split('/').pop() ?? note.path

  const rowActions = useTreeRowActions({ kind: 'file', path: note.path, label })
  const longPress = useLongPress({ onLongPress: () => rowActions.openDrawer() })
  const duplicateNote = useDuplicateNote()

  const onDuplicate = async () => {
    const existing = new Set<string>([note.path, ...siblingNotes.map((n) => n.path)])
    const new_path = nextCopyName(note.path, existing)
    try {
      await duplicateNote.mutateAsync({ src_path: note.path, new_path })
      toast.success('Duplicated')
    } catch (err) {
      if (err instanceof ApiError && err.status === 409) {
        // A racing rename/create stole our generated name — surface it
        // distinctly so the user knows to retry rather than thinking the
        // action silently failed.
        toast.error('A file with that name already exists.')
      } else {
        toast.error('Failed to duplicate')
      }
    }
  }

  const onPick = (id: ActionId) => {
    if (id === 'duplicate') {
      void onDuplicate()
      return
    }
    handlePickAction(id, rowActions, { kind: 'file', label, note, siblingNotes })
  }

  const onKeyDown = (e: KeyboardEvent<HTMLAnchorElement>) => {
    if (e.key === 'F2') {
      e.preventDefault()
      rowActions.startRename()
    } else if (e.key === 'Delete' || e.key === 'Backspace') {
      e.preventDefault()
      rowActions.startDelete()
    }
  }

  return (
    <li>
      {rowActions.renaming ? (
        <div
          className="flex items-center gap-1 py-0.5 pl-1 pr-3"
          style={{ paddingLeft: `${depth * 12 + 16}px` }}
        >
          <RenameInput
            initial={fileName}
            kind="file"
            onCommit={rowActions.commitRename}
            onCancel={rowActions.cancelRename}
          />
        </div>
      ) : (
        <Link
          to={`/note/${encodePathForRouter(note.path)}`}
          aria-current={isSelected ? 'page' : undefined}
          onContextMenu={(e) => {
            e.preventDefault()
            rowActions.openContextMenu({ x: e.clientX, y: e.clientY })
          }}
          onKeyDown={onKeyDown}
          className={`flex items-center gap-1 rounded py-0.5 pl-1 pr-3 ${
            isSelected
              ? 'bg-blue-50 dark:bg-blue-950 font-medium text-blue-700 dark:text-blue-300'
              : 'text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800'
          }`}
          style={{ paddingLeft: `${depth * 12 + 16}px` }}
          {...rowActions.dragSourceProps}
          {...longPress}
        >
          <FileIcon />
          <span className="min-w-0 flex-1 truncate">{label}</span>
          {extension && (
            <span className="shrink-0 text-xs uppercase text-gray-400 dark:text-gray-500">
              {extension}
            </span>
          )}
        </Link>
      )}

      {rowActions.menuPos && (
        <ContextMenu
          actions={actionsFor({ kind: 'file' })}
          position={rowActions.menuPos}
          onPick={onPick}
          onClose={rowActions.closeMenu}
        />
      )}
      {rowActions.drawerOpen && (
        <ActionDrawer
          title={label}
          actions={actionsFor({ kind: 'file' })}
          onPick={onPick}
          onClose={rowActions.closeDrawer}
        />
      )}
      {rowActions.showDelete && (
        <DeleteConfirm
          node={{ kind: 'file', path: note.path }}
          onConfirm={rowActions.confirmDelete}
          onCancel={rowActions.cancelDelete}
        />
      )}
      {rowActions.showMove && (
        <MoveDialog
          folders={folders.map((f) => ({ name: f.name }))}
          node={{ kind: 'file', path: note.path }}
          onPick={rowActions.commitMove}
          onCancel={rowActions.cancelMove}
        />
      )}
    </li>
  )
}

// Action dispatch — keeps the row components small. `duplicate` is handled
// one level up in NoteLeaf because it needs its own mutation hook (the rest
// can ride on the shared `rowActions` set).
function handlePickAction(
  id: ActionId,
  rowActions: ReturnType<typeof useTreeRowActions>,
  ctx:
    | { kind: 'folder'; label: string }
    | { kind: 'file'; label: string; note: NoteSummary; siblingNotes: NoteSummary[] },
) {
  switch (id) {
    case 'rename':
      rowActions.startRename()
      return
    case 'delete':
      rowActions.startDelete()
      return
    case 'move':
      rowActions.startMove()
      return
    case 'copy-wikilink':
      if (ctx.kind === 'file') void rowActions.copyWikilink(ctx.label)
      return
    case 'duplicate':
      // Handled by NoteLeaf.onPick before reaching here.
      return
  }
}

function noteLabel(note: NoteSummary): string {
  // Filename-first (Obsidian-style). Title comes from the first `# heading`
  // in content, which rename doesn't touch — if we showed title here, the
  // tree would look unchanged after a rename. Filename is canonical.
  const last = note.path.split('/').pop() ?? note.path
  // Only strip recognized extensions, otherwise "archive.tar.gz" loses ".gz"
  // and the row reads "archive.tar" + "GZ" chip — confusing.
  const ext = recognizedExtension(last)
  return ext ? last.slice(0, -(ext.length + 1)) : last
}

const KNOWN_EXTENSIONS = new Set([
  'md',
  'pdf',
  'png',
  'jpg',
  'jpeg',
  'gif',
  'webp',
  'svg',
  'mp3',
  'mp4',
  'webm',
  'mov',
  'csv',
  'json',
  'txt',
])

function recognizedExtension(filename: string): string | null {
  const dot = filename.lastIndexOf('.')
  if (dot <= 0) return null
  const ext = filename.slice(dot + 1).toLowerCase()
  return KNOWN_EXTENSIONS.has(ext) ? ext : null
}

function nonMdExtension(path: string): string | null {
  const last = path.split('/').pop() ?? path
  const ext = recognizedExtension(last)
  return ext && ext !== 'md' ? ext : null
}

function encodePathForRouter(path: string): string {
  return path.split('/').map(encodeURIComponent).join('/')
}

function decodePathFromRouter(encoded: string): string {
  return encoded
    .split('/')
    .map((s) => {
      try {
        return decodeURIComponent(s)
      } catch {
        return s
      }
    })
    .join('/')
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

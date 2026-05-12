import { Link, useLocation } from 'react-router'
import { type NoteSummary, useFolders, useFolderNotes, type Folder } from '../api/queries'
import { type SortKey, useFolderTreeState } from '../layout/folder-tree-context'

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
  // Note routes: /note/<path>. Read from pathname directly because
  // useParams() in the parent layout doesn't expose the child route's
  // splat. The pathname segments are %-encoded, decode each before
  // joining so we can compare against raw note paths.
  const selectedNotePath = location.pathname.startsWith('/note/')
    ? decodePathFromRouter(location.pathname.slice('/note/'.length))
    : null

  if (isLoading) {
    return <p className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">Loading…</p>
  }
  if (isError) {
    return <p className="px-3 py-2 text-xs text-red-600 dark:text-red-400">Failed to load folders.</p>
  }
  if (!folders || folders.length === 0) {
    return <p className="px-3 py-2 text-xs text-gray-500 dark:text-gray-400">No notes yet.</p>
  }

  const tree = buildTree(folders, sort)
  const hasRootFiles = folders.some((f) => f.name === '')

  return (
    <nav aria-label="Files" className="py-2 text-base">
      <ul role="list" className="space-y-1">
        {hasRootFiles && (
          <RootFiles selectedNotePath={selectedNotePath} />
        )}
        {tree.map((node) => (
          <FolderNode
            key={node.fullPath}
            node={node}
            depth={0}
            selectedNotePath={selectedNotePath}
          />
        ))}
      </ul>
    </nav>
  )
}

function RootFiles({ selectedNotePath }: { selectedNotePath: string | null }) {
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
        />
      ))}
    </>
  )
}

interface FolderNodeProps {
  node: TreeNode
  depth: number
  selectedNotePath: string | null
}

function FolderNode({ node, depth, selectedNotePath }: FolderNodeProps) {
  const { isOpen: getIsOpen, toggle } = useFolderTreeState()
  const containsSelected = selectedNotePath?.startsWith(`${node.fullPath}/`) ?? false
  const isOpen = getIsOpen(node.fullPath) || containsSelected

  return (
    <li>
      <button
        type="button"
        onClick={() => toggle(node.fullPath)}
        aria-expanded={isOpen}
        className="flex w-full items-center gap-1 rounded py-0.5 pl-1 pr-3 text-left text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800"
        style={{ paddingLeft: `${depth * 12 + 4}px` }}
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

      {isOpen && (
        <ul role="list" className="space-y-1">
          {node.children.map((child) => (
            <FolderNode
              key={child.fullPath}
              node={child}
              depth={depth + 1}
              selectedNotePath={selectedNotePath}
            />
          ))}
          <FolderFiles
            folderPath={node.fullPath}
            depth={depth + 1}
            selectedNotePath={selectedNotePath}
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
}: {
  folderPath: string
  depth: number
  selectedNotePath: string | null
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
        />
      ))}
    </>
  )
}

function NoteLeaf({
  note,
  depth,
  selectedNotePath,
}: {
  note: NoteSummary
  depth: number
  selectedNotePath: string | null
}) {
  const isSelected = selectedNotePath === note.path
  const extension = nonMdExtension(note.path)
  return (
    <li>
      <Link
        to={`/note/${encodePathForRouter(note.path)}`}
        aria-current={isSelected ? 'page' : undefined}
        className={`flex items-center gap-1 rounded py-0.5 pl-1 pr-3 ${
          isSelected
            ? 'bg-blue-50 dark:bg-blue-950 font-medium text-blue-700 dark:text-blue-300'
            : 'text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800'
        }`}
        style={{ paddingLeft: `${depth * 12 + 16}px` }}
      >
        <FileIcon />
        <span className="min-w-0 flex-1 truncate">{noteLabel(note)}</span>
        {extension && (
          <span className="shrink-0 text-xs uppercase text-gray-400 dark:text-gray-500">
            {extension}
          </span>
        )}
      </Link>
    </li>
  )
}

function noteLabel(note: NoteSummary): string {
  if (note.title) return note.title
  const last = note.path.split('/').pop() ?? note.path
  return last.replace(/\.[^.]+$/, '')
}

function nonMdExtension(path: string): string | null {
  const last = path.split('/').pop() ?? path
  const dot = last.lastIndexOf('.')
  if (dot <= 0) return null
  const ext = last.slice(dot + 1).toLowerCase()
  return ext === 'md' ? null : ext
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

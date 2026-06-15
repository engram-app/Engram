import { QueryClient } from '@tanstack/react-query'
import {
  FOLDER_NOTES_STALE_MS,
  ROOT_FOLDER_ID,
  type AttachmentSummary,
  type Folder,
  type NoteSummary,
} from '../../api/queries'
import type { TreeItem } from './types'
import { ROOT_ID, formatItemId, parseItemId } from './types'

export type SortKey =
  | 'name-asc' | 'name-desc'
  | 'modified-asc' | 'modified-desc'
  | 'created-asc' | 'created-desc'

interface LoaderDeps {
  folders: Folder[]
  qc: QueryClient
  vaultId: string
  sort: SortKey
  attachments?: AttachmentSummary[]
  fetchFolderNotes?: (folderId: string) => Promise<NoteSummary[]>
  onChildrenLoaded?: (folderId: string) => void
}

export interface LoaderItem {
  itemId: string
  item: TreeItem
  isFolder: boolean
}

export function buildLoader(deps: LoaderDeps) {
  return {
    getItem(itemId: string): LoaderItem | undefined {
      if (itemId === ROOT_ID) return undefined
      const p = parseItemId(itemId)
      if (p.kind === 'root') return undefined
      if (p.kind === 'folder') return folderLoaderItem(deps, p.id)
      return noteLoaderItem(deps, p.id)
    },

    getChildren(itemId: string): LoaderItem[] {
      if (itemId === ROOT_ID) return rootChildren(deps)
      const p = parseItemId(itemId)
      if (p.kind !== 'folder') return []
      return folderChildren(deps, p.id)
    },
  }
}

function folderLoaderItem(deps: LoaderDeps, id: string): LoaderItem | undefined {
  const f = deps.folders.find(x => x.id === id)
  if (!f) return undefined
  return {
    itemId: formatItemId({ kind: 'folder', id: f.id }),
    item: {
      kind: 'folder',
      id: f.id,
      path: f.name,                                   // backend `name` IS the path
      name: f.name.split('/').pop() ?? f.name,        // leaf name for display
      count: f.count,
    },
    isFolder: true,
  }
}

function noteLoaderItem(deps: LoaderDeps, id: string): LoaderItem | undefined {
  // Every note list — root (keyed under ROOT_FOLDER_ID) and subfolders — lives
  // in the one id-keyed cache, so a single scan finds the note.
  for (const [, list] of deps.qc.getQueriesData<NoteSummary[]>({ queryKey: ['folder-notes-by-id'] })) {
    const hit = list?.find(n => n.id === id)
    if (hit) return { itemId: formatItemId({ kind: 'note', id }), item: noteToTreeItem(hit), isFolder: false }
  }
  return undefined
}

function folderLoaderItems(deps: LoaderDeps, parentId: string | null): LoaderItem[] {
  return deps.folders
    .filter(f => f.parent_id === parentId)
    .sort((a, b) => folderCmp(a, b, deps.sort))
    .map(f => ({
      itemId: formatItemId({ kind: 'folder', id: f.id }),
      item: { kind: 'folder' as const, id: f.id, path: f.name, name: f.name.split('/').pop() ?? f.name, count: f.count },
      isFolder: true,
    }))
}

// Note children for a folder id (ROOT_FOLDER_ID for the vault root). Reads the
// id-keyed cache; on a miss, lazily fetches and asks HT to refetch the branch.
// Returns null on a cache miss so callers can render folders + attachments
// (but not notes) while the fetch is in flight.
function noteChildItems(deps: LoaderDeps, folderId: string): LoaderItem[] | null {
  const cached = deps.qc.getQueryData<NoteSummary[]>(['folder-notes-by-id', deps.vaultId, folderId])
  if (!cached) {
    if (deps.fetchFolderNotes) {
      const fetcher = deps.fetchFolderNotes
      deps.qc
        .fetchQuery({
          queryKey: ['folder-notes-by-id', deps.vaultId, folderId],
          queryFn: () => fetcher(folderId),
          staleTime: FOLDER_NOTES_STALE_MS,
        })
        // The notes are now in the cache, but HT cached the empty children
        // list when it first asked. Tell it to refetch this branch.
        .then(() => deps.onChildrenLoaded?.(folderId))
        .catch(() => {})
    }
    return null
  }
  return sortNotes(cached, deps.sort).map(n => ({
    itemId: formatItemId({ kind: 'note', id: n.id }),
    item: noteToTreeItem(n),
    isFolder: false,
  }))
}

function attachmentDir(path: string): string {
  const slash = path.lastIndexOf('/')
  return slash < 0 ? '' : path.slice(0, slash)
}

function attachmentToTreeItem(a: AttachmentSummary): Extract<TreeItem, { kind: 'attachment' }> {
  return { kind: 'attachment', path: a.path, mime: a.mime_type, size: a.size_bytes }
}

function attachmentItemsForDir(deps: LoaderDeps, dir: string): LoaderItem[] {
  const list = (deps.attachments ?? []).filter((a) => attachmentDir(a.path) === dir)
  const sign = deps.sort.endsWith('-desc') ? -1 : 1
  const fname = (p: string) => p.split('/').pop() ?? p
  // Honor the temporal sort key via `mtime` so attachments order consistently
  // with notes under modified-*. Attachments carry no created_at, so created-*
  // (and name-*) fall back to filename.
  const cmp =
    deps.sort.startsWith('modified')
      ? (a: AttachmentSummary, b: AttachmentSummary) => sign * (a.mtime - b.mtime)
      : (a: AttachmentSummary, b: AttachmentSummary) => sign * fname(a.path).localeCompare(fname(b.path))
  return list
    .sort(cmp)
    .map((a) => ({
      itemId: formatItemId({ kind: 'attachment', path: a.path }),
      item: attachmentToTreeItem(a),
      isFolder: false,
    }))
}

function rootChildren(deps: LoaderDeps): LoaderItem[] {
  const tops = folderLoaderItems(deps, null)
  const noteItems = noteChildItems(deps, ROOT_FOLDER_ID) ?? []
  const attItems = attachmentItemsForDir(deps, '')
  return [...tops, ...noteItems, ...attItems]
}

function folderChildren(deps: LoaderDeps, folderId: string): LoaderItem[] {
  const childFolders = folderLoaderItems(deps, folderId)
  const noteItems = noteChildItems(deps, folderId)
  const folder = deps.folders.find((f) => f.id === folderId)
  const attItems = folder ? attachmentItemsForDir(deps, folder.name) : []
  const notes = noteItems ?? []
  return [...childFolders, ...notes, ...attItems]
}

function folderCmp(a: Folder, b: Folder, sort: SortKey): number {
  const dir = sort === 'name-desc' ? -1 : 1
  return dir * (a.name.split('/').pop() ?? a.name).localeCompare(b.name.split('/').pop() ?? b.name)
}

function sortNotes(notes: NoteSummary[], sort: SortKey): NoteSummary[] {
  const sign = sort.endsWith('-desc') ? -1 : 1
  const copy = [...notes]
  if (sort.startsWith('modified'))
    return copy.sort((a, b) => sign * (Date.parse(a.updated_at) - Date.parse(b.updated_at)))
  if (sort.startsWith('created'))
    return copy.sort((a, b) => sign * (Date.parse(a.created_at) - Date.parse(b.created_at)))
  return copy.sort((a, b) => sign * a.title.localeCompare(b.title))
}

function noteToTreeItem(n: NoteSummary): Extract<TreeItem, { kind: 'note' }> {
  const last = n.path.split('/').pop() ?? n.path
  const dot = last.lastIndexOf('.')
  const ext = dot > 0 ? last.slice(dot + 1).toLowerCase() : null
  return { kind: 'note', id: n.id, path: n.path, title: n.title, ext }
}

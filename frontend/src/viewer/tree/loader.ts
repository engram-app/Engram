import { QueryClient } from '@tanstack/react-query'
import type { Folder, NoteSummary } from '../../api/queries'
import type { TreeItem } from './types'
import { ROOT_ID, formatItemId, parseItemId } from './types'

export type SortKey =
  | 'name-asc' | 'name-desc'
  | 'modified-asc' | 'modified-desc'
  | 'created-asc' | 'created-desc'

interface LoaderDeps {
  folders: Folder[]
  qc: QueryClient
  vaultId: string | number
  sort: SortKey
  rootNotes: NoteSummary[]
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

function folderLoaderItem(deps: LoaderDeps, id: number): LoaderItem | undefined {
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

function noteLoaderItem(deps: LoaderDeps, id: number): LoaderItem | undefined {
  // Note may live in any cached folder-notes-by-id list. Search them.
  for (const [, list] of deps.qc.getQueriesData<NoteSummary[]>({ queryKey: ['folder-notes-by-id'] })) {
    const hit = list?.find(n => n.id === id)
    if (hit) return { itemId: formatItemId({ kind: 'note', id }), item: noteToTreeItem(hit), isFolder: false }
  }
  return undefined
}

function rootChildren(deps: LoaderDeps): LoaderItem[] {
  const tops = deps.folders
    .filter(f => f.parent_id == null)
    .sort((a, b) => folderCmp(a, b, deps.sort))
    .map(f => ({
      itemId: formatItemId({ kind: 'folder', id: f.id }),
      item: { kind: 'folder' as const, id: f.id, path: f.name, name: f.name.split('/').pop() ?? f.name, count: f.count },
      isFolder: true,
    }))

  const noteItems = sortNotes(deps.rootNotes, deps.sort).map(n => ({
    itemId: formatItemId({ kind: 'note', id: n.id }),
    item: noteToTreeItem(n),
    isFolder: false,
  }))

  return [...tops, ...noteItems]
}

function folderChildren(deps: LoaderDeps, folderId: number): LoaderItem[] {
  const childFolders = deps.folders
    .filter(f => f.parent_id === folderId)
    .sort((a, b) => folderCmp(a, b, deps.sort))
    .map(f => ({
      itemId: formatItemId({ kind: 'folder', id: f.id }),
      item: { kind: 'folder' as const, id: f.id, path: f.name, name: f.name.split('/').pop() ?? f.name, count: f.count },
      isFolder: true,
    }))

  const cached = deps.qc.getQueryData<NoteSummary[]>(['folder-notes-by-id', deps.vaultId, folderId])
  if (!cached) {
    deps.qc.prefetchQuery({
      queryKey: ['folder-notes-by-id', deps.vaultId, folderId],
      queryFn: () => Promise.resolve([]),  // real queryFn lives in useFolderNotesById; prefetch arms it
    })
    return childFolders
  }

  const noteItems = sortNotes(cached, deps.sort).map(n => ({
    itemId: formatItemId({ kind: 'note', id: n.id }),
    item: noteToTreeItem(n),
    isFolder: false,
  }))

  return [...childFolders, ...noteItems]
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

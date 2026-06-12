import { useEffect, useMemo, useRef } from 'react'
import { useTree } from '@headless-tree/react'
import {
  syncDataLoaderFeature,
  selectionFeature,
  hotkeysCoreFeature,
  dragAndDropFeature,
  renamingFeature,
  searchFeature,
  expandAllFeature,
  type ItemInstance,
  type DragTarget,
} from '@headless-tree/core'
import { useVirtualizer } from '@tanstack/react-virtual'
import type { QueryClient } from '@tanstack/react-query'
import { buildLoader, type SortKey, type LoaderItem } from './loader'
import { ROOT_ID } from './types'
import { resolveDropMove } from './drop-redirect'
import type { Folder, NoteSummary } from '../../api/queries'

interface Deps {
  folders: Folder[]
  rootNotes: NoteSummary[]
  qc: QueryClient
  vaultId: string
  sort: SortKey
  scrollParentRef: React.RefObject<HTMLDivElement | null>
  onRenameCommit: (itemId: string, newName: string) => void
  onMove: (sourceIds: string[], targetItemId: string) => void
  fetchFolderNotes?: (folderId: string) => Promise<NoteSummary[]>
}

// Loader-side data: HT stores LoaderItem as the per-item `T`.
type Data = LoaderItem

/**
 * Stable structural fingerprint that drives `rebuildTree()`. Includes each
 * folder's `count` (not just its id) so a move/create/delete — which changes
 * counts but no folder ids — still changes the key and rebuilds the tree.
 * Without the count, headless-tree keeps a stale per-folder child list after a
 * move until the user manually collapses/expands the folder.
 */
export function treeStructureKey(
  folders: Pick<Folder, 'id' | 'count'>[],
  rootNoteIds: string[],
  sort: SortKey,
): string {
  const folderKey = folders.map((f) => `${f.id}:${f.count}`).join('|')
  return `${folderKey}::${rootNoteIds.join('|')}::${sort}`
}

export function useEngramTree(deps: Deps) {
  const treeRef = useRef<ReturnType<typeof useTree<Data>> | null>(null)
  const inner = useMemo(
    () => buildLoader({
      folders: deps.folders,
      qc: deps.qc,
      vaultId: deps.vaultId,
      sort: deps.sort,
      rootNotes: deps.rootNotes,
      fetchFolderNotes: deps.fetchFolderNotes,
      onChildrenLoaded: (folderId) => {
        const t = treeRef.current
        if (!t) return
        const inst = t.getItemInstance(`f:${folderId}`)
        // invalidateChildrenIds returns a promise but we don't need to await
        inst?.invalidateChildrenIds()
      },
    }),
    [deps.folders, deps.qc, deps.vaultId, deps.sort, deps.rootNotes, deps.fetchFolderNotes],
  )

  // Bridge our LoaderItem-returning loader to HT's TreeDataLoader<T> shape
  // (getItem -> T, getChildren -> string[]). We index getChildren results
  // by itemId so a subsequent getItem(id) lookup hits the same row data.
  const dataLoader = useMemo(() => {
    const childIndex = new Map<string, LoaderItem>()
    return {
      getItem(itemId: string): Data {
        if (itemId === ROOT_ID) {
          return {
            itemId: ROOT_ID,
            item: { kind: 'folder', id: 'root', path: '', name: '', count: 0 },
            isFolder: true,
          }
        }
        const cached = childIndex.get(itemId)
        if (cached) return cached
        const direct = inner.getItem(itemId)
        if (direct) {
          childIndex.set(itemId, direct)
          return direct
        }
        // Fallback placeholder so HT doesn't crash before data lands.
        return {
          itemId,
          item: { kind: 'folder', id: itemId, path: '', name: itemId, count: 0 },
          isFolder: false,
        }
      },
      getChildren(itemId: string): string[] {
        const kids = inner.getChildren(itemId)
        for (const k of kids) childIndex.set(k.itemId, k)
        return kids.map(k => k.itemId)
      },
    }
  }, [inner])

  const tree = useTree<Data>({
    rootItemId: ROOT_ID,
    // Without expanding root, HT renders no items — its `getItems()` walks the
    // expanded set, and an unexpanded root means the top-level folders never
    // become visible. Seed expandedItems with the root id so its direct
    // children render on first mount.
    initialState: { expandedItems: [ROOT_ID] },
    dataLoader,
    getItemName: (item: ItemInstance<Data>) => {
      const d = item.getItemData()
      if (!d) return ''
      const t = d.item
      return t.kind === 'folder' ? t.name : t.title
    },
    isItemFolder: (item: ItemInstance<Data>) => {
      const d = item.getItemData()
      return d?.isFolder ?? false
    },
    canReorder: true,
    onRename: (item: ItemInstance<Data>, value: string) =>
      deps.onRenameCommit(item.getId(), value),
    onDrop: (items: ItemInstance<Data>[], target: DragTarget<Data>) => {
      // HT normalizes `target.item` to the destination container (the parent
      // folder for between-siblings, or the folder dropped onto). We ignore the
      // insertion index and reparent into it. See drop-redirect.ts.
      const destId = (target as { item?: ItemInstance<Data> }).item?.getId()
      const sources = items.map((i) => ({
        id: i.getId(),
        parentId: i.getParent()?.getId(),
      }))
      const move = resolveDropMove(sources, destId)
      if (move) deps.onMove(move.ids, move.dest)
    },
    features: [
      syncDataLoaderFeature,
      selectionFeature,
      hotkeysCoreFeature,
      dragAndDropFeature,
      renamingFeature,
      searchFeature,
      expandAllFeature,
    ],
  })

  treeRef.current = tree

  // HT only computes its flat-item list on mount + on expandedItems change.
  // When our `useFolders` query lands after mount, the dataLoader returns new
  // ids but HT keeps its cached (empty) item list. Force a rebuild when the
  // data shape changes — keyed on stable structural fingerprints so we never
  // re-trigger from spurious identity churn (rebuildTree → setState → render
  // would otherwise spin into a max-update-depth loop).
  const structureKey = treeStructureKey(
    deps.folders,
    deps.rootNotes.map((n) => n.id),
    deps.sort,
  )
  const lastKey = useRef('')
  useEffect(() => {
    if (lastKey.current === structureKey) return
    lastKey.current = structureKey
    tree.rebuildTree()
  }, [tree, structureKey])

  const items = tree.getItems()

  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => deps.scrollParentRef.current,
    estimateSize: () => 24,
    overscan: 8,
  })

  return { tree, virtualizer, items }
}

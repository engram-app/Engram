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
    canReorder: false,
    onRename: (item: ItemInstance<Data>, value: string) =>
      deps.onRenameCommit(item.getId(), value),
    onDrop: (items: ItemInstance<Data>[], target: DragTarget<Data>) => {
      const sourceIds = items.map(i => i.getId())
      // target shape varies (item vs between-items); fall back to item id of
      // whichever container the drop lands on.
      const targetItem = (target as { item?: ItemInstance<Data> }).item
      const targetId = targetItem ? targetItem.getId() : ROOT_ID
      deps.onMove(sourceIds, targetId)
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
  const folderKey = deps.folders.map(f => f.id).join('|')
  const rootKey = deps.rootNotes.map(n => n.id).join('|')
  const lastKey = useRef('')
  useEffect(() => {
    const key = `${folderKey}::${rootKey}::${deps.sort}`
    if (lastKey.current === key) return
    lastKey.current = key
    tree.rebuildTree()
  }, [tree, folderKey, rootKey, deps.sort])

  const items = tree.getItems()

  const virtualizer = useVirtualizer({
    count: items.length,
    getScrollElement: () => deps.scrollParentRef.current,
    estimateSize: () => 24,
    overscan: 8,
  })

  return { tree, virtualizer, items }
}

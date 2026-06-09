import type { VirtualItem } from '@tanstack/react-virtual'
import type { ItemInstance } from '@headless-tree/core'
import { TreeRow } from './tree-row'
import type { LoaderItem } from './loader'

interface Props {
  virtualItem: VirtualItem
  items: ItemInstance<LoaderItem>[]
  instanceFor?: (itemId: string) => ItemInstance<LoaderItem> | undefined
}

export function TreeRowVirtualized({ virtualItem, items, instanceFor }: Props) {
  const fallback = items[virtualItem.index]
  if (!fallback) return null
  const instance = instanceFor ? instanceFor(fallback.getId()) ?? fallback : fallback

  return (
    <div
      style={{
        position: 'absolute',
        top: 0,
        left: 0,
        width: '100%',
        height: virtualItem.size,
        transform: `translateY(${virtualItem.start}px)`,
      }}
    >
      <TreeRow instance={instance} />
    </div>
  )
}

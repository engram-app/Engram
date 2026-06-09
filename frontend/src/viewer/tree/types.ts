export type TreeItem =
  | { kind: 'folder'; id: number; path: string; name: string; count: number }
  | { kind: 'note'; id: number; path: string; title: string; ext: string | null }

export type ItemId = string

export const ROOT_ID: ItemId = 'root'

export function formatItemId(input: { kind: 'folder' | 'note'; id: number }): ItemId {
  return `${input.kind === 'folder' ? 'f' : 'n'}:${input.id}`
}

export type ParsedItemId =
  | { kind: 'folder'; id: number }
  | { kind: 'note'; id: number }
  | { kind: 'root' }

export function parseItemId(id: ItemId): ParsedItemId {
  if (id === ROOT_ID) return { kind: 'root' }
  const [prefix, numStr] = id.split(':')
  const n = Number(numStr)
  if (Number.isNaN(n)) throw new Error(`Unknown tree item id: ${id}`)
  if (prefix === 'f') return { kind: 'folder', id: n }
  if (prefix === 'n') return { kind: 'note', id: n }
  throw new Error(`Unknown tree item id: ${id}`)
}

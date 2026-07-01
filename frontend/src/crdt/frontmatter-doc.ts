import type * as Y from 'yjs'

export const CONTENT_KEY = 'content'
export const FRONTMATTER_KEY = 'frontmatter'
export const ORDER_KEY = 'frontmatter_order'
export const TYPES_KEY = 'frontmatter_types'

export interface FrontmatterMaps {
  values: Y.Map<string>
  order: Y.Array<string>
  types: Y.Map<string>
}

export function frontmatterMaps(doc: Y.Doc): FrontmatterMaps {
  return {
    values: doc.getMap<string>(FRONTMATTER_KEY),
    order: doc.getArray<string>(ORDER_KEY),
    types: doc.getMap<string>(TYPES_KEY),
  }
}

export interface PropertyRow {
  key: string
  value: unknown
  typeOverride: string | null
}

export function readRows(doc: Y.Doc): PropertyRow[] {
  const { values, order, types } = frontmatterMaps(doc)
  return order.toArray().map((key) => {
    const raw = values.get(key)
    let value: unknown = raw
    if (typeof raw === 'string') {
      try {
        value = JSON.parse(raw)
      } catch {
        value = raw
      }
    }
    return { key, value, typeOverride: types.get(key) ?? null }
  })
}

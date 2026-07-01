import { useEffect, useState } from 'react'
import type * as Y from 'yjs'
import {
  addKey,
  frontmatterMaps,
  moveKey,
  readRows,
  removeKey,
  setType,
  setValue,
  type PropertyRow,
} from '../crdt/frontmatter-doc'
import { effectiveType, type PropertyType } from './property-types'
import { PropertyField } from './property-fields'
import { PropertyTypeMenu } from './property-type-menu'

export function PropertiesWidget({ doc }: { doc: Y.Doc }) {
  const [rows, setRows] = useState<PropertyRow[]>(() => readRows(doc))

  useEffect(() => {
    const refresh = () => setRows(readRows(doc))
    const { values, order, types } = frontmatterMaps(doc)
    values.observeDeep(refresh)
    order.observe(refresh)
    types.observe(refresh)
    refresh()
    return () => {
      values.unobserveDeep(refresh)
      order.unobserve(refresh)
      types.unobserve(refresh)
    }
  }, [doc])

  const [newKey, setNewKey] = useState('')
  const [newType, setNewType] = useState<PropertyType>('text')

  return (
    <div className="border-b border-border px-5 py-3">
      <dl className="grid grid-cols-[max-content_max-content_1fr_max-content] items-center gap-x-2 gap-y-1 text-xs">
        {rows.map((row) => {
          const type = effectiveType(row.value, row.typeOverride)
          return (
            <div key={row.key} className="contents">
              <dt className="font-medium text-muted-foreground">{row.key}</dt>
              <PropertyTypeMenu value={type} onChange={(t) => setType(doc, row.key, t)} />
              <dd>
                <PropertyField type={type} value={row.value} onCommit={(v) => setValue(doc, row.key, v)} />
              </dd>
              <div className="flex items-center gap-0.5 text-muted-foreground">
                <button
                  type="button"
                  aria-label={`Move ${row.key} up`}
                  onClick={() => moveKey(doc, row.key, 'up')}
                  className="rounded px-1 hover:bg-muted"
                >
                  ^
                </button>
                <button
                  type="button"
                  aria-label={`Move ${row.key} down`}
                  onClick={() => moveKey(doc, row.key, 'down')}
                  className="rounded px-1 hover:bg-muted"
                >
                  v
                </button>
                <button
                  type="button"
                  aria-label={`Remove ${row.key}`}
                  onClick={() => removeKey(doc, row.key)}
                  className="rounded px-1 hover:bg-muted hover:text-destructive"
                >
                  x
                </button>
              </div>
            </div>
          )
        })}
      </dl>
      <div className="mt-2 flex items-center gap-2">
        <input
          className="rounded border border-border bg-transparent px-2 py-1 text-xs text-foreground focus:outline-none focus:ring-1 focus:ring-ring"
          placeholder="Property name"
          value={newKey}
          onChange={(e) => setNewKey(e.target.value)}
        />
        <PropertyTypeMenu value={newType} onChange={setNewType} />
        <button
          type="button"
          aria-label="Add property"
          className="rounded border border-border px-2 py-1 text-xs text-muted-foreground hover:bg-muted"
          onClick={() => {
            if (addKey(doc, newKey, newType)) setNewKey('')
          }}
        >
          Add property
        </button>
      </div>
    </div>
  )
}

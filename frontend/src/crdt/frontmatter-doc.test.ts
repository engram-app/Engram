import { describe, expect, test } from 'vitest'
import * as Y from 'yjs'
import { FRONTMATTER_KEY, ORDER_KEY, TYPES_KEY, frontmatterMaps, readRows } from './frontmatter-doc'

function seed(doc: Y.Doc) {
  doc.transact(() => {
    const v = doc.getMap<string>(FRONTMATTER_KEY)
    v.set('title', JSON.stringify('Hi'))
    v.set('tags', JSON.stringify(['a', 'b']))
    doc.getArray<string>(ORDER_KEY).insert(0, ['title', 'tags'])
    doc.getMap<string>(TYPES_KEY).set('title', 'text')
  })
}

describe('frontmatter-doc', () => {
  test('frontmatterMaps returns the three shared types by name', () => {
    const doc = new Y.Doc()
    const m = frontmatterMaps(doc)
    expect(m.values).toBe(doc.getMap(FRONTMATTER_KEY))
    expect(m.order).toBe(doc.getArray(ORDER_KEY))
    expect(m.types).toBe(doc.getMap(TYPES_KEY))
  })

  test('readRows decodes values in order with type overrides', () => {
    const doc = new Y.Doc()
    seed(doc)
    expect(readRows(doc)).toEqual([
      { key: 'title', value: 'Hi', typeOverride: 'text' },
      { key: 'tags', value: ['a', 'b'], typeOverride: null },
    ])
  })

  test('readRows keeps the raw string when a value is not valid JSON', () => {
    const doc = new Y.Doc()
    doc.transact(() => {
      doc.getMap<string>(FRONTMATTER_KEY).set('broken', 'not json{')
      doc.getArray<string>(ORDER_KEY).insert(0, ['broken'])
    })
    expect(readRows(doc)).toEqual([{ key: 'broken', value: 'not json{', typeOverride: null }])
  })

  test('empty doc yields no rows', () => {
    expect(readRows(new Y.Doc())).toEqual([])
  })
})

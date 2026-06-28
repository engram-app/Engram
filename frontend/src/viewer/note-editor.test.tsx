import { describe, it, expect } from 'vitest'
import * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'
import { buildEditorState } from './note-editor'

// happy-dom cannot render a real CodeMirror EditorView, but EditorState.create
// is pure (no DOM), so we can verify the one thing that was actually broken:
// the editor must be SEEDED from the Y.Text. y-codemirror.next's ySync only
// forwards incremental deltas — content already present in the Y.Text at bind
// time never renders unless the initial EditorState.doc equals ytext.toString().
describe('buildEditorState', () => {
  it('seeds the editor document from the Y.Text content', () => {
    const doc = new Y.Doc()
    const ytext = doc.getText('content')
    ytext.insert(0, '# Seeded heading\n\nbody text')
    const awareness = new Awareness(doc)

    const state = buildEditorState(ytext, awareness, false)

    expect(state.doc.toString()).toBe('# Seeded heading\n\nbody text')
  })

  it('produces an empty document when the Y.Text is empty', () => {
    const doc = new Y.Doc()
    const ytext = doc.getText('content')
    const awareness = new Awareness(doc)

    const state = buildEditorState(ytext, awareness, true)

    expect(state.doc.toString()).toBe('')
  })

  it('reflects all Y.Text content at build time (seed is current, not stale)', () => {
    const doc = new Y.Doc()
    const ytext = doc.getText('content')
    const awareness = new Awareness(doc)
    ytext.insert(0, 'first')
    ytext.insert(ytext.length, ' second')

    const state = buildEditorState(ytext, awareness, false)

    expect(state.doc.toString()).toBe('first second')
  })
})

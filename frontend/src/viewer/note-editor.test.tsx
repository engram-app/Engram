import { describe, it, expect, vi } from 'vitest'
import { render } from '@testing-library/react'
import * as Y from 'yjs'
import { Awareness } from 'y-protocols/awareness'
import NoteEditor from './note-editor'

vi.mock('../theme/theme-provider', () => ({
  useTheme: () => ({ resolved: 'light' }),
}))

// CodeMirror uses layout APIs that happy-dom does not implement; its
// contenteditable stays empty. Mock the wrapper so the test can exercise the
// yCollab wiring without a real browser engine.
vi.mock('@uiw/react-codemirror', () => ({
  default: (props: { extensions?: unknown[] }) => {
    // Find the yCollab extension (tagged object from our yCollab mock below)
    // and render the Y.Text content so assertions can read it from the DOM.
    const ytextContent = (() => {
      for (const ext of props.extensions ?? []) {
        const e = ext as Record<string, unknown>
        if (e && typeof e === 'object' && 'ytext' in e) {
          return String((e.ytext as Y.Text).toString())
        }
      }
      return ''
    })()
    return (
      <div data-testid="cm" className="cm-editor">
        <div className="cm-content">{ytextContent}</div>
      </div>
    )
  },
}))

// Capture what yCollab is called with so we can verify the binding.
let lastYtext: Y.Text | null = null
let lastAwareness: Awareness | null = null
vi.mock('y-codemirror.next', () => ({
  yCollab: (ytext: Y.Text, awareness: Awareness) => {
    lastYtext = ytext
    lastAwareness = awareness
    // Return a tagged object so the mock CodeMirror above can find it.
    return { ytext, awareness }
  },
}))

describe('NoteEditor (CRDT)', () => {
  it('renders the Y.Text content and passes the correct binding to yCollab', () => {
    const doc = new Y.Doc()
    const ytext = doc.getText('content')
    ytext.insert(0, '# Hello CRDT')
    const awareness = new Awareness(doc)
    const { container } = render(
      <NoteEditor ytext={ytext} awareness={awareness} />,
    )
    // yCollab seeds the editor from the bound Y.Text.
    expect(container.querySelector('.cm-content')?.textContent).toContain('Hello CRDT')
    // The correct ytext and awareness objects are passed to yCollab.
    expect(lastYtext).toBe(ytext)
    expect(lastAwareness).toBe(awareness)
    // The Y.Text reflects mutations (real CM + yCollab would propagate these
    // into the editor view; here we verify the source-of-truth updates).
    ytext.insert(ytext.length, ' more')
    expect(ytext.toString()).toContain('more')
  })
})

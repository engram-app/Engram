import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { Prec } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import CodeMirror from '@uiw/react-codemirror'
import { useMemo } from 'react'
import { yCollab } from 'y-codemirror.next'
import type { Awareness } from 'y-protocols/awareness'
import type * as Y from 'yjs'
import { useTheme } from '../theme/theme-provider'

export interface NoteEditorProps {
  ytext: Y.Text
  awareness: Awareness
}

// Fill the parent so the editor spans the full pane height. 16px on .cm-content
// prevents iOS Safari auto-zoom. (Unchanged from the legacy editor theme.)
const editorTheme = EditorView.theme({
  '&': { height: '100%', backgroundColor: 'transparent' },
  '.cm-scroller': {
    fontFamily: 'inherit',
    overflow: 'auto',
    backgroundColor: 'transparent',
    scrollbarWidth: 'thin',
    scrollbarColor: 'var(--border) transparent',
  },
  '.cm-scroller::-webkit-scrollbar': { width: '10px', height: '10px' },
  '.cm-scroller::-webkit-scrollbar-track': { backgroundColor: 'transparent' },
  '.cm-scroller::-webkit-scrollbar-thumb': {
    backgroundColor: 'var(--border)',
    borderRadius: '9999px',
    border: '1px solid transparent',
    backgroundClip: 'padding-box',
  },
  '.cm-gutters': { backgroundColor: 'transparent', border: 'none' },
  '.cm-content': { fontSize: '16px', padding: '20px 20px 30vh' },
})

const baseExtensions = [
  markdown({ base: markdownLanguage }),
  EditorView.lineWrapping,
  Prec.highest(editorTheme),
]

const basicSetup = {
  lineNumbers: false,
  foldGutter: false,
  highlightActiveLine: false,
  highlightActiveLineGutter: false,
  autocompletion: false,
}

export default function NoteEditor({ ytext, awareness }: NoteEditorProps) {
  const { resolved } = useTheme()

  // yCollab binds CodeMirror's doc to the Y.Text — the editor is UNCONTROLLED:
  // no `value`/`onChange`. Local keystrokes mutate the Y.Text (→ channel out);
  // remote merges land on the Y.Text and flow into the view automatically.
  // Memoized per (ytext, awareness) so we don't re-bind on every render.
  const extensions = useMemo(
    () => [...baseExtensions, yCollab(ytext, awareness)],
    [ytext, awareness],
  )

  return (
    <CodeMirror
      theme={resolved}
      extensions={extensions}
      basicSetup={basicSetup}
      height="100%"
      className="h-full"
    />
  )
}

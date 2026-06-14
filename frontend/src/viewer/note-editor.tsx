import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { Prec } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import CodeMirror from '@uiw/react-codemirror'
import { forwardRef, useImperativeHandle, useRef } from 'react'
import { useTheme } from '../theme/theme-provider'
import { computeReplacement } from './merge'

export interface NoteEditorHandle {
  // Apply server/remote text into the live doc as a minimal change so the
  // caret survives. No-op when the doc already matches.
  applyRemote: (nextText: string) => void
  getDoc: () => string
}

interface NoteEditorProps {
  value: string
  onChange: (next: string) => void
}

// Fill the parent so the editor spans the full pane height — clicking anywhere
// (including the empty space below the text) lands the caret at the doc end.
// 16px on .cm-content prevents iOS Safari from auto-zooming when the soft
// keyboard opens. lineWrapping stays on.
const editorTheme = EditorView.theme({
  // Transparent so the card (bg-card) shows through — the editor background
  // matches its container instead of the @uiw theme's own surface color.
  '&': { height: '100%', backgroundColor: 'transparent' },
  '.cm-scroller': { fontFamily: 'inherit', overflow: 'auto', backgroundColor: 'transparent' },
  '.cm-gutters': { backgroundColor: 'transparent', border: 'none' },
  // Vertical only — horizontal gutters come from the card wrapper. The large
  // bottom padding keeps the empty space below the text clickable (caret-to-end).
  '.cm-content': { fontSize: '16px', padding: '20px 0 30vh' },
})

// Module scope: react-codemirror reconfigures the editor whenever the
// extensions prop identity changes — an inline array would re-instantiate the
// markdown language package on every keystroke. `markdownLanguage` base turns
// on GFM (strikethrough/tables/tasklists) for richer source highlighting.
const extensions = [
  markdown({ base: markdownLanguage }),
  EditorView.lineWrapping,
  // Prec.highest so our transparent background + layout beat the @uiw theme's
  // own surface color (otherwise the editor keeps the theme's background).
  Prec.highest(editorTheme),
]

const basicSetup = {
  lineNumbers: false,
  foldGutter: false,
  highlightActiveLine: false,
  highlightActiveLineGutter: false,
  autocompletion: false,
}

const NoteEditor = forwardRef<NoteEditorHandle, NoteEditorProps>(function NoteEditor(
  { value, onChange },
  ref,
) {
  const { resolved } = useTheme()
  const viewRef = useRef<EditorView | null>(null)

  useImperativeHandle(ref, () => ({
    applyRemote(nextText: string) {
      const view = viewRef.current
      if (!view) return
      const cur = view.state.doc.toString()
      if (cur === nextText) return
      const { from, to, insert } = computeReplacement(cur, nextText)
      view.dispatch({ changes: { from, to, insert } })
    },
    getDoc() {
      return viewRef.current?.state.doc.toString() ?? value
    },
  }))

  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      onCreateEditor={(view) => {
        viewRef.current = view
      }}
      theme={resolved}
      extensions={extensions}
      basicSetup={basicSetup}
      height="100%"
      className="h-full"
    />
  )
})

export default NoteEditor

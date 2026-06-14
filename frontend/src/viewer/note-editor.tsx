import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
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

// 16px on .cm-content prevents iOS Safari from auto-zooming when the soft
// keyboard opens. lineWrapping stays on.
const mobileSafeTheme = EditorView.theme({
  '.cm-content': { fontSize: '16px' },
  '.cm-scroller': { fontFamily: 'inherit' },
})

// Module scope: react-codemirror reconfigures the editor whenever the
// extensions prop identity changes — an inline array would re-instantiate the
// markdown language package on every keystroke. `markdownLanguage` base turns
// on GFM (strikethrough/tables/tasklists) for richer source highlighting.
const extensions = [
  markdown({ base: markdownLanguage }),
  EditorView.lineWrapping,
  mobileSafeTheme,
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
      className="min-h-[70vh] rounded-md border border-border bg-muted/30"
    />
  )
})

export default NoteEditor

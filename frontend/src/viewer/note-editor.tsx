import { markdown, markdownLanguage } from '@codemirror/lang-markdown'
import { Prec } from '@codemirror/state'
import { EditorView } from '@codemirror/view'
import CodeMirror from '@uiw/react-codemirror'
import { forwardRef, useCallback, useImperativeHandle, useRef } from 'react'
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
  // Scrollbar mirrors the reading view's Radix ScrollArea: a 10px gutter with a
  // ~8px rounded bg-border thumb over a transparent track. Firefox uses
  // scrollbar-color; WebKit/Blink uses the ::-webkit-scrollbar pseudos below.
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
  // 20px side gutters live here (not the wrapper) so .cm-scroller spans the full
  // width and its scrollbar sits at the card edge like the reading view. The
  // large bottom padding keeps the space below the text clickable (caret-to-end).
  '.cm-content': { fontSize: '16px', padding: '20px 20px 30vh' },
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
  // True while applyRemote is dispatching, so the resulting (synchronous)
  // onChange isn't echoed back as a local edit — which would schedule a
  // redundant autosave of the just-merged text at a stale version (409 loop).
  const applyingRemote = useRef(false)

  const handleChange = useCallback(
    (next: string) => {
      if (applyingRemote.current) return
      onChange(next)
    },
    [onChange],
  )

  useImperativeHandle(ref, () => ({
    applyRemote(nextText: string) {
      const view = viewRef.current
      if (!view) return
      const cur = view.state.doc.toString()
      if (cur === nextText) return
      const { from, to, insert } = computeReplacement(cur, nextText)
      applyingRemote.current = true
      try {
        view.dispatch({ changes: { from, to, insert } })
      } finally {
        applyingRemote.current = false
      }
    },
    getDoc() {
      return viewRef.current?.state.doc.toString() ?? value
    },
  }))

  return (
    <CodeMirror
      value={value}
      onChange={handleChange}
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

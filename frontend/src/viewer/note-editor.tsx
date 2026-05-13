import { markdown } from '@codemirror/lang-markdown'
import { EditorView } from '@codemirror/view'
import CodeMirror from '@uiw/react-codemirror'
import { useTheme } from '../theme/theme-provider'

interface NoteEditorProps {
  value: string
  onChange: (next: string) => void
}

// 16px on .cm-content prevents iOS Safari from auto-zooming when the
// soft keyboard opens. lineWrapping stays on.
const mobileSafeTheme = EditorView.theme({
  '.cm-content': { fontSize: '16px' },
  '.cm-scroller': { fontFamily: 'inherit' },
})

export default function NoteEditor({ value, onChange }: NoteEditorProps) {
  const { resolved } = useTheme()

  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      theme={resolved}
      extensions={[markdown(), EditorView.lineWrapping, mobileSafeTheme]}
      basicSetup={{
        lineNumbers: false,
        foldGutter: false,
        highlightActiveLine: false,
        highlightActiveLineGutter: false,
        autocompletion: false,
      }}
      className="min-h-[70vh] rounded-md border border-border bg-muted/30"
    />
  )
}

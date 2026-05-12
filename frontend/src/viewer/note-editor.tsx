import { markdown } from '@codemirror/lang-markdown'
import { EditorView } from '@codemirror/view'
import CodeMirror from '@uiw/react-codemirror'
import { useTheme } from '../theme/theme-provider'

interface NoteEditorProps {
  value: string
  onChange: (next: string) => void
}

export default function NoteEditor({ value, onChange }: NoteEditorProps) {
  const { resolved } = useTheme()

  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      theme={resolved}
      extensions={[markdown(), EditorView.lineWrapping]}
      basicSetup={{
        lineNumbers: false,
        foldGutter: false,
        highlightActiveLine: false,
        highlightActiveLineGutter: false,
        autocompletion: false,
      }}
      className="min-h-[70vh] rounded-md border border-gray-200 bg-gray-50/50 text-sm dark:border-gray-800 dark:bg-gray-950/40"
    />
  )
}

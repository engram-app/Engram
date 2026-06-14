import { lazy, Suspense, useCallback, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router'
import { toast } from 'sonner'
import { useNote, useSaveNoteContent, useFetchNoteFresh } from '../api/queries'
import { subscribeToNoteChanges } from '../api/channel'
import { useActiveVaultId } from '../api/active-vault'
import { ApiError } from '../api/client'
import { useRightSidebar } from '../layout/right-sidebar-context'
import { Button } from '@/components/ui/button'
import { ScrollArea } from '@/components/ui/scroll-area'
import NoteToc from './note-toc'
import NoteView from './note-view'
import { merge3 } from './merge'
import { useAutosave } from './use-autosave'
import type { NoteEditorHandle } from './note-editor'

// CodeMirror (language pkg + view) only loads when the editor first mounts.
const NoteEditor = lazy(() => import('./note-editor'))

type Mode = 'live' | 'reading'

export default function NotePage() {
  const params = useParams()
  const idStr = params.id
  // Note ids are uuid strings — accept any non-empty value and let the
  // backend reject malformed inputs with a 400.
  const validId = idStr && idStr.length > 0 ? idStr : null

  const { data: note, isLoading, error } = useNote(validId)
  const saveContent = useSaveNoteContent()
  const fetchFresh = useFetchNoteFresh()
  const vaultId = useActiveVaultId()
  const { setContent: setRightContent } = useRightSidebar()

  const [mode, setMode] = useState<Mode>('live')

  // `base` = last server-synced content; the common ancestor for 3-way merges.
  const baseRef = useRef('')
  // `doc` = latest local editor content (mirror, for merges before mount).
  const docRef = useRef('')
  const editorRef = useRef<NoteEditorHandle | null>(null)

  // The editor is fed a per-note INITIAL value and keyed by path; live
  // refetches must not reset it (that would clobber in-progress typing).
  // Seeded once per note during render (ref mutation is render-safe).
  const seededPath = useRef<string | null>(null)
  const initialRef = useRef('')

  // Persist content at a base version; resolve with the new version. On a 409
  // (another device saved first) rebase via 3-way merge and retry.
  const save = useCallback(
    async (content: string, version: number): Promise<number> => {
      if (!note) return version
      try {
        const v = await saveContent(note.path, content, version)
        baseRef.current = content
        return v
      } catch (e) {
        if (e instanceof ApiError && e.status === 409) {
          const fresh = await fetchFresh(note.id)
          const { text: merged } = merge3(baseRef.current, content, fresh.content)
          docRef.current = merged
          editorRef.current?.applyRemote(merged)
          const v = await saveContent(note.path, merged, fresh.version)
          baseRef.current = merged
          return v
        }
        throw e
      }
    },
    [note, saveContent, fetchFresh],
  )

  const autosave = useAutosave({ save, version: note?.version ?? 0 })
  const { onEdit, flush } = autosave

  // Seed base/doc/initial when navigating to a different note (render-time).
  if (note && seededPath.current !== note.path) {
    seededPath.current = note.path
    baseRef.current = note.content
    docRef.current = note.content
    initialRef.current = note.content
  }

  // Apply incoming remote edits to the open note via 3-way merge. The merged
  // text re-enters the editor, whose onChange schedules an autosave so the
  // reconciliation persists.
  useEffect(() => {
    if (!note) return
    return subscribeToNoteChanges((p) => {
      if (p.id !== note.id || p.vault_id !== vaultId || p.content == null) return
      const local = editorRef.current?.getDoc() ?? docRef.current
      const { text, conflict } = merge3(baseRef.current, local, p.content)
      baseRef.current = p.content
      docRef.current = text
      editorRef.current?.applyRemote(text)
      if (conflict) toast.message('Merged a conflicting change from another device')
    })
  }, [note?.id, vaultId]) // eslint-disable-line react-hooks/exhaustive-deps

  // Signal the onboarding tour that the user opened a note (step 1 gate).
  useEffect(() => {
    if (!note?.path) return
    window.dispatchEvent(
      new CustomEvent('engram:note-opened', { detail: { path: note.path } }),
    )
  }, [note?.path])

  // ToC in both modes.
  useEffect(() => {
    if (!note) {
      setRightContent(null)
      return
    }
    setRightContent(<NoteToc content={note.content} />)
    return () => setRightContent(null)
  }, [note?.path, note?.content, setRightContent])

  // Flush pending edits before switching notes or unmounting.
  useEffect(() => {
    return () => {
      void flush()
    }
  }, [note?.path, flush]) // eslint-disable-line react-hooks/exhaustive-deps

  const onEditorChange = useCallback(
    (next: string) => {
      docRef.current = next
      onEdit(next)
    },
    [onEdit],
  )

  if (validId === null) return <p className="p-6 text-destructive">Invalid note id.</p>
  if (isLoading) return <p className="p-6 text-muted-foreground">Loading note…</p>
  if (error) return <p className="p-6 text-destructive">Failed to load note: {error.message}</p>
  if (!note) return <p className="p-6 text-muted-foreground">Note not found</p>

  const statusLabel =
    autosave.status === 'saving'
      ? 'Saving…'
      : autosave.status === 'error'
        ? 'Retry'
        : autosave.status === 'saved'
          ? 'Saved'
          : ''

  // folder/file path for the header; long paths ellipsis from the LEFT
  // (dir=rtl below) so the filename end stays visible: ".../folder/file".
  const titlePath = note.folder ? `${note.folder}/${note.title}` : note.title

  return (
    <section className="mx-auto -my-6 flex h-[calc(100%+3rem)] min-h-0 w-full min-w-0 max-w-[840px] flex-col overflow-hidden border-x border-border bg-card text-card-foreground">
      <div className="flex shrink-0 items-center gap-3 border-b border-border px-4 py-2">
        <span className="min-w-0 flex-1 truncate text-xs text-muted-foreground" aria-live="polite">
          {statusLabel}
        </span>
        <h2
          dir="rtl"
          className="min-w-0 flex-1 truncate text-center text-sm font-medium"
          title={titlePath}
        >
          {titlePath}
        </h2>
        <div className="flex min-w-0 flex-1 justify-end">
          <Button
            variant="ghost"
            size="sm"
            onClick={() => setMode((m) => (m === 'live' ? 'reading' : 'live'))}
          >
            {mode === 'live' ? '↗ Reading view' : '✎ Edit'}
          </Button>
        </div>
      </div>

      {mode === 'reading' ? (
        <ScrollArea className="min-h-0 flex-1">
          <div className="w-full px-5 py-5">
            <NoteView content={note.content} tags={note.tags} />
          </div>
        </ScrollArea>
      ) : (
        // Full-height editor: fills the pane so clicking anywhere (even below
        // the text) places the caret. No horizontal padding here — the text
        // gutter lives on .cm-content so the scroller (and its scrollbar) spans
        // the full width and the scrollbar sits at the card edge, matching the
        // reading view's ScrollArea.
        <div className="min-h-0 flex-1 overflow-hidden" data-tour="note-editor">
          <Suspense fallback={<p className="py-5 text-muted-foreground">Loading editor…</p>}>
            <NoteEditor
              key={note.path}
              ref={editorRef}
              value={initialRef.current}
              onChange={onEditorChange}
            />
          </Suspense>
        </div>
      )}
    </section>
  )
}

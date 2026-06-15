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
import LoadingPane from './loading-pane'
import NoteToc from './note-toc'
import NoteView from './note-view'
import { merge3 } from './merge'
import { useAutosave } from './use-autosave'
import { ConflictBar } from './conflict-bar'
import type { NoteEditorHandle } from './note-editor'

// A remote change that conflicts with the open draft (line-level overlap).
// We hold the three candidate texts so the user can pick a resolution from
// the non-blocking ConflictBar instead of having markers written silently.
interface PendingConflict {
  mine: string
  theirs: string
  merged: string
}

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
  // Non-null while a conflicting remote change is awaiting the user's choice.
  const [conflict, setConflict] = useState<PendingConflict | null>(null)

  // `base` = last server-synced content; the common ancestor for 3-way merges.
  const baseRef = useRef('')
  // `doc` = latest local editor content. Mirrors the live doc (updated on every
  // edit and remote merge) and is the value the editor (re)mounts with — so a
  // mode toggle that unmounts/remounts the editor restores in-progress edits
  // rather than the stale per-note initial content.
  const docRef = useRef('')
  const editorRef = useRef<NoteEditorHandle | null>(null)

  // The editor is keyed by path; live refetches must not reset it (that would
  // clobber in-progress typing). Seeded once per note during render (ref
  // mutation is render-safe).
  const seededPath = useRef<string | null>(null)

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
          let fresh: Awaited<ReturnType<typeof fetchFresh>>
          try {
            fresh = await fetchFresh(note.id)
          } catch (fe) {
            // The note was deleted on another device mid-edit: there's nothing
            // to rebase onto. Surface it specifically instead of a generic
            // retry loop, then let the save settle into the error state.
            if (fe instanceof ApiError && fe.status === 404) {
              toast.error('This note was deleted on another device.')
            }
            throw fe
          }
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

  const autosave = useAutosave({
    save,
    version: note?.version ?? 0,
    noteId: note?.id ?? null,
    onError: (e) => {
      // 404 (deleted) is toasted specifically in `save`; avoid double-toasting.
      if (e instanceof ApiError && e.status === 404) return
      toast.error('Couldn’t save your changes — use Retry to try again.')
    },
  })
  const { onEdit, flush, setVersion } = autosave

  // Seed base/doc when navigating to a different note (render-time).
  if (note && seededPath.current !== note.path) {
    seededPath.current = note.path
    baseRef.current = note.content
    docRef.current = note.content
  }

  // Apply incoming remote edits to the open note via 3-way merge. applyRemote
  // no longer echoes through onChange (see note-editor), so persist any merged-
  // in local edits explicitly: adopt the remote version as the new base, then
  // schedule a save of the merged text only when it differs from the remote.
  //
  // On a CLEAN merge this stays silent (the draft + remote fold together). On a
  // TRUE conflict (line-level overlap) we do NOT write git-style markers into
  // the doc; instead we keep the local draft visible and surface the
  // non-blocking ConflictBar so the user picks the resolution. base/version
  // still advance to the remote so a subsequent save rebases onto it.
  useEffect(() => {
    if (!note) return
    return subscribeToNoteChanges((p) => {
      if (p.id !== note.id || p.vault_id !== vaultId || p.content == null) return
      const remote = p.content
      const local = editorRef.current?.getDoc() ?? docRef.current
      const { text, conflict: hasConflict } = merge3(baseRef.current, local, remote)
      baseRef.current = remote
      if (p.version != null) setVersion(p.version)
      if (hasConflict) {
        // Keep the draft in the editor untouched; offer the choice.
        setConflict({ mine: local, theirs: remote, merged: text })
      } else {
        docRef.current = text
        editorRef.current?.applyRemote(text)
        if (text !== remote) onEdit(text)
      }
    })
  }, [note?.id, vaultId]) // eslint-disable-line react-hooks/exhaustive-deps

  // Resolve an open conflict with the user's explicit choice. The local draft
  // is never silently discarded: 'mine' persists the live draft over the new
  // remote base, 'theirs' adopts the remote, 'merge' writes the marker'd text
  // for manual cleanup. base/version already advanced when the conflict was
  // raised, so each path saves at the right version.
  const resolveConflict = useCallback(
    (choice: 'mine' | 'theirs' | 'merge') => {
      if (!conflict) return
      if (choice === 'theirs') {
        docRef.current = conflict.theirs
        editorRef.current?.applyRemote(conflict.theirs)
        // Matches the remote base already saved elsewhere — no save needed.
      } else if (choice === 'merge') {
        docRef.current = conflict.merged
        editorRef.current?.applyRemote(conflict.merged)
        onEdit(conflict.merged)
      } else {
        // Keep mine: persist whatever is currently in the editor (the draft,
        // plus any keystrokes since the conflict was raised).
        const live = editorRef.current?.getDoc() ?? conflict.mine
        docRef.current = live
        onEdit(live)
      }
      setConflict(null)
    },
    [conflict, onEdit],
  )

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
  if (isLoading) return <LoadingPane />
  if (error) return <p className="p-6 text-destructive">Failed to load note: {error.message}</p>
  if (!note) return <p className="p-6 text-muted-foreground">Note not found</p>

  const statusLabel =
    autosave.status === 'saving'
      ? 'Saving…'
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
          {autosave.status === 'error' ? (
            <button
              type="button"
              onClick={() => void autosave.retry()}
              className="font-medium text-destructive underline-offset-2 hover:underline"
            >
              Save failed — Retry
            </button>
          ) : (
            statusLabel
          )}
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

      {conflict && (
        <ConflictBar
          onKeepMine={() => resolveConflict('mine')}
          onTakeTheirs={() => resolveConflict('theirs')}
          onViewMerge={() => resolveConflict('merge')}
          onDismiss={() => resolveConflict('mine')}
        />
      )}

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
              value={docRef.current}
              onChange={onEditorChange}
            />
          </Suspense>
        </div>
      )}
    </section>
  )
}

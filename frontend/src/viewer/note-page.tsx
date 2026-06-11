import { useEffect, useState } from 'react'
import { useParams } from 'react-router'
import { toast } from 'sonner'
import { useNote, useUpdateNote } from '../api/queries'
import { useRightSidebar } from '../layout/right-sidebar-context'
import { Button } from '@/components/ui/button'
import { ScrollArea } from '@/components/ui/scroll-area'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import NoteEditor from './note-editor'
import NoteToc from './note-toc'
import NoteView from './note-view'
import { useRemoteUpdateBanner } from './use-remote-update-banner'

type Mode = 'preview' | 'edit'

export default function NotePage() {
  const params = useParams()
  const idStr = params.id
  // Note ids are uuid strings — accept any non-empty value and let the
  // backend reject malformed inputs with a 400. We don't pre-validate
  // because the canonical shape (uuidv7) is opaque to the frontend.
  const validId = idStr && idStr.length > 0 ? idStr : null

  const { data: note, isLoading, error } = useNote(validId)
  const update = useUpdateNote()
  const { setContent: setRightContent } = useRightSidebar()

  const [mode, setMode] = useState<Mode>('preview')
  const [draft, setDraft] = useState('')

  // Sync draft only when the user navigates to a different note. Re-syncing
  // on every `note.content` change would clobber in-progress edits whenever
  // React Query refetched (window focus, channel-driven invalidation, etc.).
  useEffect(() => {
    if (note) setDraft(note.content)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [note?.path])

  // Signal the onboarding tour that the user opened a note. The controller
  // listens for this on window and advances any gated step bound to it.
  useEffect(() => {
    if (!note?.path) return
    window.dispatchEvent(
      new CustomEvent('engram:note-opened', { detail: { path: note.path } }),
    )
  }, [note?.path])

  // Signal the tour that the user switched into Edit mode for the first
  // time. Gated step "Rendered live" listens for this and advances.
  useEffect(() => {
    if (mode !== 'edit') return
    window.dispatchEvent(new CustomEvent('engram:edit-mode-entered'))
  }, [mode])

  // Push the ToC into the app-shell right sidebar while we're in preview;
  // clear it when leaving the page or switching to edit mode.
  useEffect(() => {
    if (!note || mode !== 'preview') {
      setRightContent(null)
      return
    }
    setRightContent(<NoteToc content={note.content} />)
    return () => setRightContent(null)
  }, [note?.path, note?.content, mode, setRightContent])

  // Must run on every render — calling after the early returns below would
  // change hook count between the loading/loaded states and crash React.
  const remoteUpdate = useRemoteUpdateBanner(note?.content ?? '', draft)

  if (validId === null) {
    return <p className="p-6 text-destructive">Invalid note id.</p>
  }
  if (isLoading) {
    return <p className="p-6 text-muted-foreground">Loading note…</p>
  }
  if (error) {
    return <p className="p-6 text-destructive">Failed to load note: {error.message}</p>
  }
  if (!note) {
    return <p className="p-6 text-muted-foreground">Note not found</p>
  }

  const dirty = draft !== note.content
  const saving = update.isPending

  const handleSave = async () => {
    try {
      await update.mutateAsync({ path: note.path, content: draft, version: note.version })
      toast.success('Note saved')
      setMode('preview')
    } catch (err) {
      toast.error('Failed to save note', {
        description: err instanceof Error ? err.message : String(err),
      })
    }
  }

  return (
    <Tabs
      value={mode}
      onValueChange={(v) => setMode(v as Mode)}
      className="flex h-full min-h-0 min-w-0 flex-col overflow-hidden bg-card text-card-foreground shadow-sm ring-1 ring-border/60 md:rounded-2xl"
    >
      <div className="flex shrink-0 items-center justify-between gap-3 border-b border-border px-4 py-2">
        <TabsList variant="line" data-tour="note-tabs">
          <TabsTrigger value="preview">Preview</TabsTrigger>
          <TabsTrigger value="edit">Edit</TabsTrigger>
        </TabsList>
        {mode === 'edit' && (
          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setDraft(note.content)}
              disabled={!dirty || saving}
            >
              Revert
            </Button>
            <Button size="sm" onClick={handleSave} disabled={!dirty || saving}>
              {saving ? 'Saving…' : 'Save'}
            </Button>
          </div>
        )}
      </div>

      <TabsContent
        value="preview"
        forceMount
        className="min-h-0 flex-1 data-[state=inactive]:hidden"
      >
        <ScrollArea className="h-full">
          <NoteView
            content={note.content}
            title={note.title}
            tags={note.tags}
            updatedAt={note.updated_at}
          />
        </ScrollArea>
      </TabsContent>
      <TabsContent
        value="edit"
        forceMount
        className="min-h-0 flex-1 data-[state=inactive]:hidden"
      >
        {mode === 'edit' && remoteUpdate.show && (
          <div
            role="status"
            className="flex shrink-0 items-center justify-between gap-3 border-b border-amber-500/40 bg-amber-500/10 px-4 py-2 text-sm text-amber-900 dark:text-amber-200"
          >
            <span>This note was updated elsewhere. Your unsaved edits are still here.</span>
            <div className="flex items-center gap-2">
              <Button
                variant="ghost"
                size="sm"
                onClick={() => setDraft(remoteUpdate.remoteContent)}
              >
                Discard mine &amp; reload
              </Button>
              <Button variant="outline" size="sm" onClick={remoteUpdate.acknowledge}>
                Keep mine
              </Button>
            </div>
          </div>
        )}
        <ScrollArea className="h-full">
          <div className="px-6 py-6 lg:px-8 lg:py-8" data-tour="note-editor">
            <NoteEditor value={draft} onChange={setDraft} />
          </div>
        </ScrollArea>
      </TabsContent>
    </Tabs>
  )
}

import { useEffect, useState } from 'react'
import { useParams } from 'react-router'
import { toast } from 'sonner'
import { useNote, useUpdateNote } from '../api/queries'
import { Button } from '@/components/ui/button'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@/components/ui/tabs'
import NoteEditor from './note-editor'
import NoteToc from './note-toc'
import NoteView from './note-view'

type Mode = 'preview' | 'edit'

export default function NotePage() {
  // React Router v7 uses "*" for catch-all params
  const params = useParams()
  const path = params['*'] ?? ''

  const { data: note, isLoading, error } = useNote(path)
  const update = useUpdateNote()

  const [mode, setMode] = useState<Mode>('preview')
  const [draft, setDraft] = useState('')

  useEffect(() => {
    if (note) setDraft(note.content)
  }, [note?.path, note?.content])

  if (!path) {
    return <p className="p-6 text-muted-foreground">No note selected</p>
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
    <div className="mx-auto grid h-full w-full max-w-[100rem] gap-6 lg:grid-cols-[1fr_15rem]">
      <Tabs
        value={mode}
        onValueChange={(v) => setMode(v as Mode)}
        className="flex min-h-0 min-w-0 flex-col overflow-hidden rounded-2xl bg-card text-card-foreground shadow-sm ring-1 ring-border/60"
      >
        <div className="flex shrink-0 items-center justify-between gap-3 border-b border-border px-4 py-2">
          <TabsList variant="line">
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
          className="min-h-0 flex-1 overflow-y-auto data-[state=inactive]:hidden"
        >
          <NoteView
            content={note.content}
            title={note.title}
            tags={note.tags}
            updatedAt={note.updated_at}
          />
        </TabsContent>
        <TabsContent
          value="edit"
          forceMount
          className="min-h-0 flex-1 overflow-y-auto data-[state=inactive]:hidden"
        >
          <div className="px-6 py-6 lg:px-8 lg:py-8">
            <NoteEditor value={draft} onChange={setDraft} />
          </div>
        </TabsContent>
      </Tabs>

      {mode === 'preview' && (
        <aside className="hidden min-h-0 overflow-y-auto lg:block">
          <NoteToc content={note.content} />
        </aside>
      )}
    </div>
  )
}

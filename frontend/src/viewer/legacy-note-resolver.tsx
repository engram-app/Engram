import { useEffect } from 'react'
import { useNavigate, useParams } from 'react-router'
import { useNoteByPath } from '../api/queries'

export function LegacyNoteResolver() {
  const params = useParams()
  const path = params['*'] ?? ''
  const navigate = useNavigate()
  const { data: note, isLoading, isError } = useNoteByPath(path)

  useEffect(() => {
    if (note?.id != null) {
      navigate(`/note/${note.id}`, { replace: true })
    }
  }, [note?.id, navigate])

  if (isLoading) return <p className="p-4 text-sm text-muted-foreground">Loading…</p>
  if (isError) return <p className="p-4 text-sm text-destructive">Note not found.</p>
  return null
}

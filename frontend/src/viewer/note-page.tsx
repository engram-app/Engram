import { useParams } from 'react-router'
import { useNote } from '../api/queries'
import NoteView from './note-view'

export default function NotePage() {
  // React Router v7 uses "*" for catch-all params
  const params = useParams()
  const path = params['*'] ?? ''

  const { data: note, isLoading, error } = useNote(path)

  if (!path) {
    return <p>No note selected</p>
  }

  if (isLoading) {
    return <p>Loading note...</p>
  }

  if (error) {
    return <p className="text-red-600 dark:text-red-400">Failed to load note: {error.message}</p>
  }

  if (!note) {
    return <p>Note not found</p>
  }

  return (
    <NoteView
      content={note.content}
      title={note.title}
      tags={note.tags}
      updatedAt={note.updated_at}
    />
  )
}

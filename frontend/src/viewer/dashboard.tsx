import { Link, useSearchParams } from 'react-router'
import { useFolderNotes, useVaults, type NoteSummary } from '../api/queries'
import { EmptyVaultState } from '../layout/empty-vault-state'

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  })
}

interface NoteRowProps {
  note: NoteSummary
}

function NoteRow({ note }: NoteRowProps) {
  return (
    <article className="border-b border-gray-100 dark:border-gray-800 py-3 last:border-0">
      <Link
        to={`/note/${encodeURIComponent(note.path)}`}
        className="block hover:text-blue-700"
      >
        <h3 className="text-sm font-medium text-gray-900 dark:text-gray-100">{note.title || note.path}</h3>
      </Link>
      <footer className="mt-1 flex flex-wrap items-center gap-3 text-xs text-gray-500 dark:text-gray-400">
        {note.folder && <span>{note.folder}</span>}
        {note.tags.length > 0 && (
          <ul className="flex gap-1" aria-label="Tags">
            {note.tags.map((tag) => (
              <li
                key={tag}
                className="rounded bg-gray-100 dark:bg-gray-800 px-1.5 py-0.5 text-gray-600 dark:text-gray-300"
              >
                {tag}
              </li>
            ))}
          </ul>
        )}
        <time dateTime={note.updated_at}>{formatDate(note.updated_at)}</time>
      </footer>
    </article>
  )
}

function FolderNotes({ folder }: { folder: string }) {
  const { data: notes, isLoading, isError } = useFolderNotes(folder)

  if (isLoading) return <p className="text-sm text-gray-500 dark:text-gray-400">Loading…</p>
  if (isError) return <p className="text-sm text-red-600 dark:text-red-400">Failed to load notes.</p>
  if (!notes || notes.length === 0) {
    return <p className="text-sm text-gray-500 dark:text-gray-400">No notes in this folder.</p>
  }

  return (
    <section aria-label={`Notes in ${folder}`}>
      <ul role="list">
        {notes.map((note) => (
          <li key={note.path}>
            <NoteRow note={note} />
          </li>
        ))}
      </ul>
    </section>
  )
}

export default function Dashboard() {
  const [searchParams] = useSearchParams()
  const folder = searchParams.get('folder') ?? ''
  const { data: vaults } = useVaults()

  // Deleting the last vault leaves zero active vaults. Show a create-a-vault
  // prompt instead of the (empty) note browser. Guard against the loading
  // state (vaults === undefined) so the empty state doesn't flash while the
  // vault list is still in flight.
  if (vaults && vaults.length === 0) {
    return <EmptyVaultState />
  }

  if (folder) {
    return (
      <>
        <header className="mb-4">
          <h2 className="text-base font-semibold text-gray-800 dark:text-gray-200">{folder}</h2>
        </header>
        <FolderNotes folder={folder} />
      </>
    )
  }

  return (
    <section aria-label="Welcome" className="flex h-full flex-col items-center justify-center text-center">
      <h2 className="text-xl font-semibold text-gray-800 dark:text-gray-200">Welcome to Engram</h2>
      <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">
        Select a folder from the sidebar to browse your notes.
      </p>
      <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">
        Use <Link to="/search" className="text-blue-600 hover:underline">Search</Link> to find notes by keyword or semantic query.
      </p>
    </section>
  )
}

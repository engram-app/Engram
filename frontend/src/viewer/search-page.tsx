import { useState, useDeferredValue } from 'react'
import { Link } from 'react-router'
import { type SearchResult, useSearch } from '../api/queries'

export default function SearchPage() {
  const [input, setInput] = useState('')
  const deferredQuery = useDeferredValue(input.trim())
  const { data: results, isLoading, error } = useSearch(deferredQuery)

  return (
    <section className="mx-auto max-w-3xl">
      <h1 className="mb-4 text-xl font-semibold text-gray-900 dark:text-gray-100">Search</h1>
      <input
        type="search"
        placeholder="Search your notes…"
        value={input}
        onChange={(e) => setInput(e.target.value)}
        className="mb-6 w-full rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 placeholder-gray-400 dark:placeholder-gray-500 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200"
        autoFocus
      />

      {isLoading && <p className="text-sm text-gray-500 dark:text-gray-400">Searching…</p>}
      {error && (
        <p className="text-sm text-red-600 dark:text-red-400">Search failed: {error.message}</p>
      )}

      {results && results.length === 0 && deferredQuery && !isLoading && (
        <p className="text-sm text-gray-500 dark:text-gray-400">No results for "{deferredQuery}"</p>
      )}

      {results && results.length > 0 && (
        <ul className="space-y-2">
          {results.map((r) => (
            <li key={r.path}>
              <ResultCard result={r} query={deferredQuery} />
            </li>
          ))}
        </ul>
      )}

      {!deferredQuery && !isLoading && (
        <p className="text-sm text-gray-400 dark:text-gray-500">Type to search your notes.</p>
      )}
    </section>
  )
}

function ResultCard({ result, query }: { result: SearchResult; query: string }) {
  const href = `/note/${result.path.split('/').map(encodeURIComponent).join('/')}`

  return (
    <Link
      to={href}
      className="block rounded-md border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-4 transition hover:border-blue-300 hover:bg-blue-50/40 dark:hover:border-blue-700 dark:hover:bg-blue-950/40"
    >
      {result.folder && (
        <p className="text-xs text-gray-400 dark:text-gray-500">{result.folder}</p>
      )}
      <p className="mt-0.5 text-base font-medium text-gray-900 dark:text-gray-100">
        {result.title || lastSegment(result.path)}
      </p>
      {result.heading_path && result.heading_path !== result.title && (
        <p className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">↳ {result.heading_path}</p>
      )}
      {result.snippet && (
        <p className="mt-2 text-sm text-gray-700 dark:text-gray-200 line-clamp-3">
          {highlightQuery(result.snippet, query)}
        </p>
      )}
      {result.match_count > 1 && (
        <p className="mt-2 text-xs text-gray-400 dark:text-gray-500">
            +{result.match_count - 1} more match{result.match_count - 1 === 1 ? '' : 'es'} in this note
        </p>
      )}
    </Link>
  )
}

function lastSegment(path: string): string {
  return (path.split('/').pop() ?? path).replace(/\.md$/, '')
}

// Wraps each whitespace-separated query token with <mark>, case-insensitive.
// `String.split` with a capture group keeps delimiters in odd-indexed slots,
// which is how we distinguish matched tokens from surrounding text without
// re-running the regex (and without tripping on the global flag's lastIndex).
function highlightQuery(text: string, query: string): React.ReactNode {
  const tokens = query.split(/\s+/).filter((t) => t.length >= 2)
  if (tokens.length === 0) return text

  const escaped = tokens.map((t) => t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
  const re = new RegExp(`(${escaped.join('|')})`, 'gi')
  const parts = text.split(re)

  return parts.map((part, i) =>
    i % 2 === 1 ? (
      <mark key={i} className="bg-yellow-100 dark:bg-yellow-900 text-gray-900 dark:text-gray-100">
        {part}
      </mark>
    ) : (
      <span key={i}>{part}</span>
    ),
  )
}

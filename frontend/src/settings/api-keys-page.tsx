import { useRef, useState } from 'react'
import {
  type ApiKey,
  type CreatedApiKey,
  useApiKeys,
  useCreateApiKey,
  useRevokeApiKey,
} from '../api/queries'
import { ApiError } from '../api/client'

export default function ApiKeysPage() {
  const { data: keys, isLoading, error } = useApiKeys()
  const [showCreate, setShowCreate] = useState(false)
  const [newKey, setNewKey] = useState<CreatedApiKey | null>(null)

  return (
    <article className="space-y-6">
      <header className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-gray-900 dark:text-gray-100">API Keys</h1>
          <p className="mt-1 text-sm text-gray-600 dark:text-gray-300">
            Used by the Obsidian plugin and MCP clients to access your vault.
          </p>
        </div>
        <button
          type="button"
          onClick={() => setShowCreate(true)}
          className="rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          + New Key
        </button>
      </header>

      {error && (
        <p className="rounded-md bg-red-50 dark:bg-red-950 px-3 py-2 text-sm text-red-700 dark:text-red-200" role="alert">
          Failed to load API keys: {error instanceof Error ? error.message : 'unknown error'}
        </p>
      )}

      {isLoading ? (
        <p className="text-sm text-gray-500 dark:text-gray-400">Loading…</p>
      ) : keys && keys.length > 0 ? (
        <ApiKeyTable keys={keys} />
      ) : (
        <EmptyState />
      )}

      {showCreate && (
        <CreateKeyModal
          onClose={() => setShowCreate(false)}
          onCreated={(k) => {
            setNewKey(k)
            setShowCreate(false)
          }}
        />
      )}

      {newKey && <RevealKeyModal createdKey={newKey} onClose={() => setNewKey(null)} />}
    </article>
  )
}

function EmptyState() {
  return (
    <section className="rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-8 text-center">
      <p className="text-sm text-gray-600 dark:text-gray-300">
        No API keys yet. Generate one to connect Claude Desktop, MCP, or the Obsidian plugin.
      </p>
    </section>
  )
}

function ApiKeyTable({ keys }: { keys: ApiKey[] }) {
  const revoke = useRevokeApiKey()

  return (
    <section className="overflow-hidden rounded-lg border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900">
      <table className="w-full text-sm">
        <thead className="bg-gray-50 dark:bg-gray-950 text-left text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-3 font-medium">Name</th>
            <th className="px-4 py-3 font-medium">Key</th>
            <th className="px-4 py-3 font-medium">Created</th>
            <th className="px-4 py-3 font-medium">Last used</th>
            <th className="px-4 py-3" />
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {keys.map((k) => (
            <tr key={k.id}>
              <td className="px-4 py-3 font-medium text-gray-900 dark:text-gray-100">{k.name || '(unnamed)'}</td>
              <td className="px-4 py-3 font-mono text-xs text-gray-500 dark:text-gray-400">engram_••••••</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-300">{formatDate(k.created_at)}</td>
              <td className="px-4 py-3 text-gray-600 dark:text-gray-300">
                {k.last_used ? formatDate(k.last_used) : '—'}
              </td>
              <td className="px-4 py-3 text-right">
                <button
                  type="button"
                  disabled={revoke.isPending}
                  onClick={() => {
                    if (confirm(`Revoke "${k.name || 'this key'}"? This cannot be undone.`)) {
                      revoke.mutate(k.id)
                    }
                  }}
                  className="text-sm text-red-600 hover:text-red-800 disabled:opacity-50"
                >
                  Revoke
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function CreateKeyModal({
  onClose,
  onCreated,
}: {
  onClose: () => void
  onCreated: (k: CreatedApiKey) => void
}) {
  const [name, setName] = useState('')
  const create = useCreateApiKey()

  async function submit(e: React.FormEvent) {
    e.preventDefault()
    if (name.trim().length === 0) return
    try {
      const created = await create.mutateAsync(name.trim())
      onCreated(created)
    } catch {
      /* error surfaced via create.error */
    }
  }

  return (
    <ModalShell onClose={onClose} title="New API Key">
      <form onSubmit={submit} className="space-y-4">
        <label className="block">
          <span className="text-sm font-medium text-gray-700 dark:text-gray-200">Name</span>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. iPhone MCP"
            maxLength={64}
            className="mt-1 block w-full rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          />
          <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">
            Helps you identify the key later — pick something memorable.
          </span>
        </label>

        {create.error && (
          <p className="text-sm text-red-600" role="alert">
            {create.error instanceof ApiError
              ? create.error.message
              : 'Could not create key. Try again.'}
          </p>
        )}

        <footer className="flex justify-end gap-2 pt-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={create.isPending || name.trim().length === 0}
            className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            {create.isPending ? 'Generating…' : 'Generate Key'}
          </button>
        </footer>
      </form>
    </ModalShell>
  )
}

function RevealKeyModal({
  createdKey,
  onClose,
}: {
  createdKey: CreatedApiKey
  onClose: () => void
}) {
  const [copyState, setCopyState] = useState<'idle' | 'copied' | 'error'>('idle')
  const keyFieldRef = useRef<HTMLInputElement>(null)

  async function copy() {
    const ok = await copyToClipboard(createdKey.key)
    setCopyState(ok ? 'copied' : 'error')
    if (ok) {
      setTimeout(() => setCopyState('idle'), 2000)
    }
  }

  function selectAll() {
    keyFieldRef.current?.select()
  }

  return (
    <ModalShell onClose={onClose} title="Save your API key">
      <div className="space-y-4">
        <p className="rounded-md bg-amber-50 dark:bg-amber-950 px-3 py-2 text-sm text-amber-800 dark:text-amber-200">
          This is the only time the key will be shown. Copy it now and store it somewhere safe.
        </p>

        <div className="flex items-stretch gap-2">
          <input
            ref={keyFieldRef}
            readOnly
            value={createdKey.key}
            onFocus={selectAll}
            onClick={selectAll}
            className="flex-1 min-w-0 rounded-md border border-gray-300 dark:border-gray-700 bg-gray-50 dark:bg-gray-950 px-3 py-2 font-mono text-sm text-gray-900 dark:text-gray-100 focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
            aria-label="API key"
          />
          <button
            type="button"
            onClick={copy}
            aria-label="Copy API key"
            className="inline-flex shrink-0 items-center gap-1.5 rounded-md border border-blue-600 bg-blue-600 px-3 py-2 text-sm font-medium text-white shadow-sm transition-colors hover:bg-blue-700 active:bg-blue-800 active:scale-[0.98]"
          >
            <CopyIcon copied={copyState === 'copied'} />
            <span className="min-w-12 text-left">
              {copyState === 'copied' ? 'Copied' : 'Copy'}
            </span>
          </button>
        </div>

        {copyState === 'error' && (
          <p className="text-sm text-red-700" role="alert">
            Copy failed — click the field and press Cmd/Ctrl+C to copy manually.
          </p>
        )}

        <footer className="flex justify-end pt-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-4 py-2 text-sm font-medium text-gray-700 dark:text-gray-200 shadow-sm hover:bg-gray-50 dark:hover:bg-gray-800"
          >
            Done
          </button>
        </footer>
      </div>
    </ModalShell>
  )
}

function CopyIcon({ copied }: { copied: boolean }) {
  if (copied) {
    return (
      <svg
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
        className="h-4 w-4"
        aria-hidden="true"
      >
        <path
          fillRule="evenodd"
          d="M16.704 5.293a1 1 0 010 1.414l-7.5 7.5a1 1 0 01-1.414 0l-3.5-3.5a1 1 0 111.414-1.414L8.5 12.086l6.79-6.793a1 1 0 011.414 0z"
          clipRule="evenodd"
        />
      </svg>
    )
  }
  return (
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 20 20"
      fill="currentColor"
      className="h-4 w-4"
      aria-hidden="true"
    >
      <path d="M7 3a2 2 0 00-2 2v9a2 2 0 002 2h6a2 2 0 002-2V5a2 2 0 00-2-2H7z" />
      <path d="M3 7a2 2 0 012-2h.5a.5.5 0 010 1H5a1 1 0 00-1 1v9a1 1 0 001 1h7a1 1 0 001-1v-.5a.5.5 0 011 0v.5a2 2 0 01-2 2H5a2 2 0 01-2-2V7z" />
    </svg>
  )
}

async function copyToClipboard(text: string): Promise<boolean> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text)
      return true
    } catch {
      // fall through to legacy fallback
    }
  }

  try {
    const ta = document.createElement('textarea')
    ta.value = text
    ta.setAttribute('readonly', '')
    ta.style.position = 'fixed'
    ta.style.top = '0'
    ta.style.left = '0'
    ta.style.opacity = '0'
    document.body.appendChild(ta)
    ta.select()
    const ok = document.execCommand('copy')
    document.body.removeChild(ta)
    return ok
  } catch {
    return false
  }
}

function ModalShell({
  title,
  onClose,
  children,
}: {
  title: string
  onClose: () => void
  children: React.ReactNode
}) {
  return (
    <section
      role="dialog"
      aria-modal="true"
      aria-labelledby="modal-title"
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
      onClick={onClose}
    >
      <article
        className="w-full max-w-md rounded-lg bg-white dark:bg-gray-900 p-6 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="mb-4">
          <h2 id="modal-title" className="text-lg font-semibold text-gray-900 dark:text-gray-100">
            {title}
          </h2>
        </header>
        {children}
      </article>
    </section>
  )
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  })
}

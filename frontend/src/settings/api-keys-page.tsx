import { useState } from 'react'
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
          <h1 className="text-2xl font-bold text-gray-900">API Keys</h1>
          <p className="mt-1 text-sm text-gray-600">
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
        <p className="rounded-md bg-red-50 px-3 py-2 text-sm text-red-700" role="alert">
          Failed to load API keys: {error instanceof Error ? error.message : 'unknown error'}
        </p>
      )}

      {isLoading ? (
        <p className="text-sm text-gray-500">Loading…</p>
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
    <section className="rounded-lg border border-dashed border-gray-300 p-8 text-center">
      <p className="text-sm text-gray-600">
        No API keys yet. Generate one to connect Claude Desktop, MCP, or the Obsidian plugin.
      </p>
    </section>
  )
}

function ApiKeyTable({ keys }: { keys: ApiKey[] }) {
  const revoke = useRevokeApiKey()

  return (
    <section className="overflow-hidden rounded-lg border border-gray-200 bg-white">
      <table className="w-full text-sm">
        <thead className="bg-gray-50 text-left text-xs uppercase tracking-wide text-gray-500">
          <tr>
            <th className="px-4 py-3 font-medium">Name</th>
            <th className="px-4 py-3 font-medium">Key</th>
            <th className="px-4 py-3 font-medium">Created</th>
            <th className="px-4 py-3 font-medium">Last used</th>
            <th className="px-4 py-3" />
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100">
          {keys.map((k) => (
            <tr key={k.id}>
              <td className="px-4 py-3 font-medium text-gray-900">{k.name || '(unnamed)'}</td>
              <td className="px-4 py-3 font-mono text-xs text-gray-500">engram_••••••</td>
              <td className="px-4 py-3 text-gray-600">{formatDate(k.created_at)}</td>
              <td className="px-4 py-3 text-gray-600">
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
          <span className="text-sm font-medium text-gray-700">Name</span>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. iPhone MCP"
            maxLength={64}
            className="mt-1 block w-full rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none focus:ring-1 focus:ring-blue-500"
          />
          <span className="mt-1 block text-xs text-gray-500">
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
            className="rounded-md px-4 py-2 text-sm text-gray-700 hover:bg-gray-100"
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
  const [copied, setCopied] = useState(false)

  async function copy() {
    await navigator.clipboard.writeText(createdKey.key)
    setCopied(true)
    setTimeout(() => setCopied(false), 2000)
  }

  return (
    <ModalShell onClose={onClose} title="Save your API key">
      <div className="space-y-4">
        <p className="rounded-md bg-amber-50 px-3 py-2 text-sm text-amber-800">
          This is the only time the key will be shown. Copy it now and store it somewhere safe.
        </p>

        <section className="rounded-md border border-gray-200 bg-gray-50 p-3">
          <p className="break-all font-mono text-sm text-gray-900">{createdKey.key}</p>
        </section>

        <button
          type="button"
          onClick={copy}
          className="w-full rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
        >
          {copied ? 'Copied!' : 'Copy to clipboard'}
        </button>

        <footer className="flex justify-end pt-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md px-4 py-2 text-sm text-gray-700 hover:bg-gray-100"
          >
            Done
          </button>
        </footer>
      </div>
    </ModalShell>
  )
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
        className="w-full max-w-md rounded-lg bg-white p-6 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="mb-4">
          <h2 id="modal-title" className="text-lg font-semibold text-gray-900">
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

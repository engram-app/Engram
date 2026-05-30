import { useRef, useState } from 'react'
import { Plug } from 'lucide-react'
import {
  type Connection,
  type CreatedApiKey,
  useBillingStatus,
  useConnections,
  useCreatePat,
  useRevokeDeviceConnection,
  useRevokeOauthConnection,
  useRevokePat,
} from '../api/queries'
import { ApiError } from '../api/client'

// ── Tier caps ─────────────────────────────────────────────────

function useTierCaps() {
  const { data } = useBillingStatus()
  const tier = data?.tier ?? 'free'
  const isFree = tier === 'free' || tier === 'none'
  return {
    tier,
    isFree,
    apiWriteEnabled: !isFree, // PAT minting allowed on paid tiers
    obsidianCap: isFree ? 1 : null, // null = unlimited
    mcpCap: isFree ? 1 : null,
  }
}

// ── Page ──────────────────────────────────────────────────────

export default function ConnectionsPage() {
  const { data: connections, isLoading, error } = useConnections()
  const caps = useTierCaps()
  const revokeOauth = useRevokeOauthConnection()
  const revokeDevice = useRevokeDeviceConnection()
  const revokePat = useRevokePat()

  if (isLoading) return <p className="text-sm text-muted-foreground">Loading…</p>
  if (error)
    return (
      <p role="alert" className="rounded-md bg-destructive/10 px-3 py-2 text-sm text-destructive">
        Failed to load: {error instanceof Error ? error.message : 'unknown error'}
      </p>
    )

  const list = connections ?? []
  const obs = list.filter((c) => c.kind === 'obsidian')
  const mcp = list.filter((c) => c.kind === 'mcp')
  const pats = list.filter((c) => c.kind === 'pat')

  const obsCount =
    caps.obsidianCap != null ? `${obs.length} / ${caps.obsidianCap}` : `${obs.length}`
  const mcpCount = caps.mcpCap != null ? `${mcp.length} / ${caps.mcpCap}` : `${mcp.length}`

  return (
    <article className="space-y-8 max-w-3xl">
      <header>
        <h1 className="text-xl font-semibold text-foreground">Connections</h1>
        <p className="mt-1 text-sm text-muted-foreground">
          Manage what's connected to your Engram account.
        </p>
      </header>

      <section aria-labelledby="obs-h">
        <h2 id="obs-h" className="mb-3 text-lg font-semibold">
          Obsidian plugins ({obsCount})
        </h2>
        {obs.length === 0 ? (
          <EmptyState text="Install the Engram Vault Sync plugin in Obsidian to connect this vault." />
        ) : (
          <ul className="space-y-3">
            {obs.map((c) => (
              <li key={`${c.kind}-${c.client_id}`}>
                <ConnectionCard
                  connection={c}
                  onRevoke={() => {
                    if (window.confirm(`Revoke "${c.name}"? The plugin will lose access.`)) {
                      // Obsidian uses device-flow exclusively today; route all Obsidian
                      // revocations through the device endpoint. When MCP-style Obsidian
                      // clients ship we will need a discriminator field from the backend.
                      revokeDevice.mutate(c.client_id!)
                    }
                  }}
                />
              </li>
            ))}
          </ul>
        )}
      </section>

      <section aria-labelledby="mcp-h">
        <h2 id="mcp-h" className="mb-3 text-lg font-semibold">
          AI tools &amp; integrations ({mcpCount})
        </h2>
        {mcp.length === 0 ? (
          <EmptyState text="Connect Claude Desktop, Cursor, or another MCP client to use Engram as a tool." />
        ) : (
          <ul className="space-y-3">
            {mcp.map((c) => (
              <li key={`${c.kind}-${c.client_id}`}>
                <ConnectionCard
                  connection={c}
                  onRevoke={() => {
                    if (window.confirm(`Revoke "${c.name}"?`)) {
                      revokeOauth.mutate(c.client_id!)
                    }
                  }}
                />
              </li>
            ))}
          </ul>
        )}
      </section>

      <PatSection
        pats={pats}
        canCreate={caps.apiWriteEnabled}
        onRevoke={(id) => revokePat.mutate(id)}
      />
    </article>
  )
}

// ── ConnectionCard ────────────────────────────────────────────

function ConnectionCard({
  connection,
  onRevoke,
}: {
  connection: Connection
  onRevoke: () => void
}) {
  const subtitle = connection.verified
    ? `${connection.software_version ? connection.software_version + ' · ' : ''}verified`
    : 'Unverified client'

  return (
    <article className="rounded-lg border border-border bg-card p-4 flex gap-4">
      {connection.logo ? (
        <img src={connection.logo} alt="" className="size-10 rounded" />
      ) : (
        <div
          className="size-10 rounded bg-muted flex items-center justify-center text-muted-foreground"
          aria-hidden
        >
          <Plug className="size-5" />
        </div>
      )}
      <div className="flex-1 space-y-1">
        <header className="flex items-baseline gap-2">
          <h3 className="font-medium">{connection.name ?? 'Unnamed'}</h3>
          <small className="text-muted-foreground">{subtitle}</small>
        </header>
        <dl className="grid grid-cols-[max-content_1fr] gap-x-3 text-sm text-muted-foreground">
          {connection.vault_id != null && (
            <>
              <dt>Vault:</dt>
              <dd>{connection.vault_id}</dd>
            </>
          )}
          {connection.last_used_at && (
            <>
              <dt>Last active:</dt>
              <dd>{new Date(connection.last_used_at).toLocaleString()}</dd>
            </>
          )}
          {connection.scope && (
            <>
              <dt>Scopes:</dt>
              <dd>{connection.scope}</dd>
            </>
          )}
        </dl>
        <details className="text-xs text-muted-foreground">
          <summary className="cursor-pointer">Details</summary>
          <dl className="grid grid-cols-[max-content_1fr] gap-x-3 mt-1">
            <dt>Identifier:</dt>
            <dd className="font-mono break-all">{connection.client_id ?? connection.key_id}</dd>
            {connection.first_ip && (
              <>
                <dt>First IP:</dt>
                <dd>{connection.first_ip}</dd>
              </>
            )}
            {connection.first_user_agent && (
              <>
                <dt>User agent:</dt>
                <dd className="break-all">{connection.first_user_agent}</dd>
              </>
            )}
            {connection.redirect_uris.length > 0 && (
              <>
                <dt>Redirects:</dt>
                <dd>{connection.redirect_uris.join(', ')}</dd>
              </>
            )}
          </dl>
        </details>
      </div>
      <button
        type="button"
        onClick={onRevoke}
        className="self-start text-sm text-destructive hover:text-destructive/80"
      >
        Revoke
      </button>
    </article>
  )
}

// ── EmptyState ────────────────────────────────────────────────

function EmptyState({ text }: { text: string }) {
  return (
    <section className="rounded-lg border border-dashed border-input p-8 text-center">
      <p className="text-sm text-muted-foreground">{text}</p>
    </section>
  )
}

// ── PatSection ────────────────────────────────────────────────

function PatSection({
  pats,
  canCreate,
  onRevoke,
}: {
  pats: Connection[]
  canCreate: boolean
  onRevoke: (id: number) => void
}) {
  const [showCreate, setShowCreate] = useState(false)
  const [newKey, setNewKey] = useState<{ key: string; id: number; name: string } | null>(null)

  return (
    <section aria-labelledby="pat-h">
      <header className="flex flex-col gap-3 mb-3 sm:flex-row sm:items-center sm:justify-between">
        <h2 id="pat-h" className="text-lg font-semibold">
          API keys ({pats.length})
        </h2>
        {canCreate && (
          <button
            type="button"
            onClick={() => setShowCreate(true)}
            className="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          >
            + New Key
          </button>
        )}
      </header>

      {!canCreate && (
        <aside className="mb-4 flex items-center justify-between gap-4 rounded-lg border border-border bg-muted/50 px-4 py-3">
          <p className="text-sm text-muted-foreground">
            Upgrade to Starter to create API keys for scripting and external integrations.
          </p>
          <a
            href="/settings/billing"
            className="shrink-0 rounded-md bg-primary px-3 py-1.5 text-sm font-medium text-primary-foreground hover:bg-primary/90"
          >
            Upgrade
          </a>
        </aside>
      )}

      {pats.length === 0 ? (
        <EmptyState text="No API keys yet. Generate one to connect scripts or external tools." />
      ) : (
        <section className="overflow-hidden rounded-lg border border-border bg-card">
          <div className="overflow-x-auto">
            <table className="w-full min-w-[640px] text-sm">
              <thead className="bg-muted text-left text-xs uppercase tracking-wide text-muted-foreground">
                <tr>
                  <th className="px-4 py-3 font-medium">Name</th>
                  <th className="px-4 py-3 font-medium">Key</th>
                  <th className="px-4 py-3 font-medium">Created</th>
                  <th className="px-4 py-3 font-medium">Last used</th>
                  <th className="px-4 py-3" />
                </tr>
              </thead>
              <tbody className="divide-y divide-border">
                {pats.map((p) => (
                  <tr key={p.key_id}>
                    <td className="px-4 py-3 font-medium text-foreground">
                      {p.name || '(unnamed)'}
                    </td>
                    <td className="px-4 py-3 font-mono text-xs text-muted-foreground">
                      engram_••••••
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">
                      {p.connected_at ? formatDate(p.connected_at) : '—'}
                    </td>
                    <td className="px-4 py-3 text-muted-foreground">
                      {p.last_used_at ? formatDate(p.last_used_at) : '—'}
                    </td>
                    <td className="px-4 py-3 text-right">
                      <button
                        type="button"
                        onClick={() => {
                          if (window.confirm(`Revoke "${p.name || 'this key'}"? This cannot be undone.`)) {
                            onRevoke(p.key_id!)
                          }
                        }}
                        className="text-sm text-destructive hover:text-destructive/80"
                      >
                        Revoke
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      )}

      {showCreate && (
        <CreatePatModal
          onClose={() => setShowCreate(false)}
          onCreated={(k) => {
            setNewKey(k)
            setShowCreate(false)
          }}
        />
      )}

      {newKey && <RevealKeyModal createdKey={newKey} onClose={() => setNewKey(null)} />}
    </section>
  )
}

// ── CreatePatModal ────────────────────────────────────────────

function CreatePatModal({
  onClose,
  onCreated,
}: {
  onClose: () => void
  onCreated: (k: CreatedApiKey) => void
}) {
  const [name, setName] = useState('')
  const create = useCreatePat()

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
          <span className="text-sm font-medium text-foreground">Name</span>
          <input
            autoFocus
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="e.g. ci-bot"
            maxLength={64}
            className="mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring"
          />
          <span className="mt-1 block text-xs text-muted-foreground">
            Helps you identify the key later — pick something memorable.
          </span>
        </label>

        {create.error && (
          <p className="text-sm text-destructive" role="alert">
            {create.error instanceof ApiError
              ? create.error.message
              : 'Could not create key. Try again.'}
          </p>
        )}

        <footer className="flex justify-end gap-2 pt-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md px-4 py-2 text-sm text-foreground hover:bg-accent"
          >
            Cancel
          </button>
          <button
            type="submit"
            disabled={create.isPending || name.trim().length === 0}
            className="rounded-md bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:bg-primary/90 disabled:opacity-50"
          >
            {create.isPending ? 'Generating…' : 'Generate Key'}
          </button>
        </footer>
      </form>
    </ModalShell>
  )
}

// ── RevealKeyModal ────────────────────────────────────────────

function RevealKeyModal({
  createdKey,
  onClose,
}: {
  createdKey: { key: string; id: number; name: string }
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
            className="flex-1 min-w-0 rounded-md border border-input bg-muted px-3 py-2 font-mono text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring"
            aria-label="API key"
          />
          <button
            type="button"
            onClick={copy}
            aria-label="Copy API key"
            className="inline-flex shrink-0 items-center gap-1.5 rounded-md border border-primary bg-primary px-3 py-2 text-sm font-medium text-primary-foreground shadow-sm transition-colors hover:bg-primary/90 active:scale-[0.98]"
          >
            <CopyIcon copied={copyState === 'copied'} />
            <span className="min-w-12 text-left">
              {copyState === 'copied' ? 'Copied' : 'Copy'}
            </span>
          </button>
        </div>

        {copyState === 'error' && (
          <p className="text-sm text-destructive" role="alert">
            Copy failed — click the field and press Cmd/Ctrl+C to copy manually.
          </p>
        )}

        <footer className="flex justify-end pt-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-input bg-card px-4 py-2 text-sm font-medium text-foreground shadow-sm hover:bg-accent"
          >
            Done
          </button>
        </footer>
      </div>
    </ModalShell>
  )
}

// ── Shared helpers ────────────────────────────────────────────

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
        className="w-full max-w-md rounded-lg bg-card p-6 shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="mb-4">
          <h2 id="modal-title" className="text-lg font-semibold text-foreground">
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

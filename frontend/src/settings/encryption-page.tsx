import { useState } from 'react'
import {
  type EncryptionStatus,
  type Vault,
  useEncryptVault,
  useEncryptionProgress,
  useVaults,
} from '../api/queries'
import { ApiError } from '../api/client'

export default function EncryptionPage() {
  const { data: vaults, isLoading } = useVaults()

  if (isLoading) {
    return <p className="text-sm text-gray-500 dark:text-gray-400">Loading…</p>
  }

  if (!vaults || vaults.length === 0) {
    return (
      <article className="space-y-4">
        <h1 className="text-2xl font-bold text-gray-900 dark:text-gray-100">Encryption at Rest</h1>
        <section className="rounded-lg border border-dashed border-gray-300 dark:border-gray-700 p-8 text-center">
          <p className="text-sm text-gray-600 dark:text-gray-300">
            Connect a vault from the Obsidian plugin to enable encryption.
          </p>
        </section>
      </article>
    )
  }

  return (
    <article className="space-y-6">
      <header>
        <h1 className="text-2xl font-bold text-gray-900 dark:text-gray-100">Encryption at Rest</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-300">
          {vaults.length === 1
            ? 'Vault encryption status.'
            : `${vaults.length} vaults — manage encryption per vault.`}
        </p>
      </header>

      <ul className="space-y-4">
        {vaults.map((v) => (
          <li key={v.id}>
            <VaultEncryptionCard vault={v} />
          </li>
        ))}
      </ul>
    </article>
  )
}

function VaultEncryptionCard({ vault }: { vault: Vault }) {
  const inFlight =
    vault.encryption_status === 'encrypting' || vault.encryption_status === 'decrypt_pending'
  const { data: progress } = useEncryptionProgress(vault.id, inFlight)
  const encrypt = useEncryptVault()
  const [confirming, setConfirming] = useState(false)

  return (
    <section className="rounded-lg border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-6 space-y-4">
      <header className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="truncate text-base font-semibold text-gray-900 dark:text-gray-100">{vault.name}</h2>
          {vault.is_default && (
            <p className="text-xs text-gray-500 dark:text-gray-400">Default vault</p>
          )}
        </div>
        <StatusBadge status={vault.encryption_status} />
      </header>

      {vault.encryption_status === 'none' && (
        <>
          <p className="text-sm text-gray-700 dark:text-gray-200">
            Notes and vector payloads are stored as plaintext on the server. Enabling encryption
            protects your data with a key derived from your account.
          </p>
          {vault.cooldown_days != null && vault.cooldown_days > 0 && (
            <p className="text-xs text-gray-500 dark:text-gray-400">
              After enabling, you cannot disable encryption for {vault.cooldown_days} days.
            </p>
          )}
          {!confirming ? (
            <button
              type="button"
              onClick={() => setConfirming(true)}
              className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
            >
              Encrypt Vault
            </button>
          ) : (
            <ConfirmEncrypt
              cooldownDays={vault.cooldown_days}
              isPending={encrypt.isPending && encrypt.variables === vault.id}
              error={encrypt.variables === vault.id ? encrypt.error : null}
              onCancel={() => setConfirming(false)}
              onConfirm={() => {
                encrypt.mutate(vault.id, { onSuccess: () => setConfirming(false) })
              }}
            />
          )}
        </>
      )}

      {inFlight && progress && (
        <ProgressView
          processed={progress.processed}
          total={progress.total}
          status={progress.status}
        />
      )}

      {vault.encryption_status === 'encrypted' && (
        <p className="text-sm text-gray-700 dark:text-gray-200">
          All notes and vector payloads are encrypted.
          {vault.encrypted_at && (
            <> Enabled {new Date(vault.encrypted_at).toLocaleDateString()}.</>
          )}
        </p>
      )}
    </section>
  )
}

type BadgeStyle = { bg: string; text: string; dot: string; label: string }

const STATUS_STYLES: Record<EncryptionStatus, BadgeStyle> = {
  none: { bg: 'bg-gray-100 dark:bg-gray-800', text: 'text-gray-700 dark:text-gray-200', dot: 'bg-gray-400', label: 'Not encrypted' },
  encrypting: {
    bg: 'bg-blue-50 dark:bg-blue-950',
    text: 'text-blue-700 dark:text-blue-300',
    dot: 'bg-blue-500 animate-pulse',
    label: 'Encrypting…',
  },
  encrypted: {
    bg: 'bg-green-50 dark:bg-green-950',
    text: 'text-green-700 dark:text-green-300',
    dot: 'bg-green-500',
    label: 'Encrypted',
  },
  decrypt_pending: {
    bg: 'bg-amber-50 dark:bg-amber-950',
    text: 'text-amber-700 dark:text-amber-300',
    dot: 'bg-amber-500 animate-pulse',
    label: 'Decrypt pending…',
  },
}

const UNKNOWN_STYLE: BadgeStyle = {
  bg: 'bg-gray-100 dark:bg-gray-800',
  text: 'text-gray-700 dark:text-gray-200',
  dot: 'bg-gray-400',
  label: 'Unknown',
}

function StatusBadge({ status }: { status: EncryptionStatus | string }) {
  const s = STATUS_STYLES[status as EncryptionStatus] ?? {
    ...UNKNOWN_STYLE,
    label: `Unknown (${status})`,
  }

  return (
    <span
      className={`inline-flex shrink-0 items-center gap-2 rounded-full px-3 py-1 text-xs font-medium ${s.bg} ${s.text}`}
    >
      <span className={`h-2 w-2 rounded-full ${s.dot}`} />
      {s.label}
    </span>
  )
}

function ProgressView({
  processed,
  total,
  status,
}: {
  processed: number
  total: number
  status: EncryptionStatus
}) {
  const percent = total > 0 ? Math.min(100, Math.round((processed / total) * 100)) : 0
  const verb = status === 'encrypting' ? 'Encrypting' : 'Decrypt pending —'

  return (
    <section aria-live="polite" className="space-y-2">
      <p className="text-sm text-gray-700 dark:text-gray-200">
        {verb} {processed.toLocaleString()} of {total.toLocaleString()} notes ({percent}%)
      </p>
      <div className="h-2 overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700">
        <div
          className="h-full rounded-full bg-blue-500 transition-all"
          style={{ width: `${percent}%` }}
        />
      </div>
    </section>
  )
}

function ConfirmEncrypt({
  cooldownDays,
  isPending,
  error,
  onCancel,
  onConfirm,
}: {
  cooldownDays: number | null
  isPending: boolean
  error: Error | null
  onCancel: () => void
  onConfirm: () => void
}) {
  return (
    <section className="rounded-md border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950 p-4 space-y-3">
      <p className="text-sm font-medium text-amber-900 dark:text-amber-200">Encrypt this vault?</p>
      <ul className="ml-4 list-disc space-y-1 text-sm text-amber-800 dark:text-amber-300">
        <li>All existing notes will be re-encrypted in the background.</li>
        <li>Vector search continues to work — payloads are encrypted too.</li>
        {cooldownDays != null && cooldownDays > 0 && (
          <li>You cannot disable encryption for {cooldownDays} days afterward.</li>
        )}
      </ul>

      {error && (
        <p className="text-sm text-red-700" role="alert">
          {error instanceof ApiError ? error.message : 'Failed to start encryption.'}
        </p>
      )}

      <footer className="flex gap-2">
        <button
          type="button"
          onClick={onCancel}
          className="rounded-md px-4 py-2 text-sm text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800"
        >
          Cancel
        </button>
        <button
          type="button"
          onClick={onConfirm}
          disabled={isPending}
          className="rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
        >
          {isPending ? 'Starting…' : 'Yes, encrypt vault'}
        </button>
      </footer>
    </section>
  )
}

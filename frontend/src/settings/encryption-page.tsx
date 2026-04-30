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
    return <p className="text-sm text-gray-500">Loading…</p>
  }

  const vault = vaults?.[0]

  if (!vault) {
    return (
      <article className="space-y-4">
        <h1 className="text-2xl font-bold text-gray-900">Encryption at Rest</h1>
        <section className="rounded-lg border border-dashed border-gray-300 p-8 text-center">
          <p className="text-sm text-gray-600">
            Connect a vault from the Obsidian plugin to enable encryption.
          </p>
        </section>
      </article>
    )
  }

  return <EncryptionPanel vault={vault} />
}

function EncryptionPanel({ vault }: { vault: Vault }) {
  const inFlight =
    vault.encryption_status === 'encrypting' || vault.encryption_status === 'decrypting'

  const { data: progress } = useEncryptionProgress(vault.id, inFlight)
  const encrypt = useEncryptVault()
  const [confirming, setConfirming] = useState(false)

  return (
    <article className="space-y-6">
      <header>
        <h1 className="text-2xl font-bold text-gray-900">Encryption at Rest</h1>
        <p className="mt-1 text-sm text-gray-600">Vault: {vault.name}</p>
      </header>

      <section className="rounded-lg border border-gray-200 bg-white p-6 space-y-4">
        <StatusBadge status={vault.encryption_status} />

        {vault.encryption_status === 'disabled' && (
          <>
            <p className="text-sm text-gray-700">
              Notes and vector payloads are stored as plaintext on the server. Enabling
              encryption protects your data with a key derived from your account.
            </p>
            {vault.cooldown_days != null && vault.cooldown_days > 0 && (
              <p className="text-xs text-gray-500">
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
                isPending={encrypt.isPending}
                error={encrypt.error}
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

        {vault.encryption_status === 'enabled' && (
          <p className="text-sm text-gray-700">
            All notes and vector payloads are encrypted.
            {vault.encrypted_at && (
              <> Enabled {new Date(vault.encrypted_at).toLocaleDateString()}.</>
            )}
          </p>
        )}
      </section>
    </article>
  )
}

function StatusBadge({ status }: { status: EncryptionStatus }) {
  const styles: Record<EncryptionStatus, { bg: string; text: string; dot: string; label: string }> =
    {
      disabled: { bg: 'bg-gray-100', text: 'text-gray-700', dot: 'bg-gray-400', label: 'Disabled' },
      encrypting: {
        bg: 'bg-blue-50',
        text: 'text-blue-700',
        dot: 'bg-blue-500 animate-pulse',
        label: 'Encrypting…',
      },
      enabled: {
        bg: 'bg-green-50',
        text: 'text-green-700',
        dot: 'bg-green-500',
        label: 'Encrypted',
      },
      decrypting: {
        bg: 'bg-amber-50',
        text: 'text-amber-700',
        dot: 'bg-amber-500 animate-pulse',
        label: 'Decrypting…',
      },
    }

  const s = styles[status]

  return (
    <span
      className={`inline-flex items-center gap-2 rounded-full px-3 py-1 text-xs font-medium ${s.bg} ${s.text}`}
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
  const verb = status === 'encrypting' ? 'Encrypting' : 'Decrypting'

  return (
    <section aria-live="polite" className="space-y-2">
      <p className="text-sm text-gray-700">
        {verb} {processed.toLocaleString()} of {total.toLocaleString()} notes ({percent}%)
      </p>
      <div className="h-2 overflow-hidden rounded-full bg-gray-200">
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
    <section className="rounded-md border border-amber-200 bg-amber-50 p-4 space-y-3">
      <p className="text-sm font-medium text-amber-900">Encrypt this vault?</p>
      <ul className="ml-4 list-disc space-y-1 text-sm text-amber-800">
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
          className="rounded-md px-4 py-2 text-sm text-gray-700 hover:bg-gray-100"
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

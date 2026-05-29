import { useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from '@/settings/account/section-card'
import { useVaults, useDeleteVault, useUpdateVault, type Vault } from '@/api/queries'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function ActiveVaultsSection() {
  const { data: vaults, isLoading } = useVaults()

  return (
    <SettingsSectionCard title="Vaults" description="Rename, set a default, or delete your vaults.">
      {isLoading && <p className="text-sm text-muted-foreground">Loading…</p>}
      <ul className="divide-y divide-border">
        {(vaults ?? []).map((v) => (
          <VaultRow key={v.id} vault={v} />
        ))}
      </ul>
    </SettingsSectionCard>
  )
}

function VaultRow({ vault }: { vault: Vault }) {
  const update = useUpdateVault()
  const del = useDeleteVault()
  const [renaming, setRenaming] = useState(false)
  const [name, setName] = useState(vault.name)
  const [confirming, setConfirming] = useState(false)
  const [phrase, setPhrase] = useState('')

  function saveName() {
    const next = name.trim()
    if (next && next !== vault.name) {
      update.mutate({ id: vault.id, name: next }, { onError: () => toast.error('Rename failed') })
    }
    setRenaming(false)
  }

  return (
    <li className="py-3">
      <div className="flex items-center justify-between gap-3">
        {renaming ? (
          <input
            autoFocus
            className={inputClass}
            value={name}
            aria-label={`Rename ${vault.name}`}
            onChange={(e) => setName(e.target.value)}
            onBlur={saveName}
            onKeyDown={(e) => e.key === 'Enter' && saveName()}
          />
        ) : (
          <button type="button" className="text-sm font-medium text-foreground" onClick={() => setRenaming(true)}>
            {vault.name}
          </button>
        )}
        <div className="flex items-center gap-2">
          {vault.is_default ? (
            <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">Default</span>
          ) : (
            <Button
              variant="ghost"
              size="sm"
              onClick={() =>
                update.mutate({ id: vault.id, is_default: true }, { onError: () => toast.error('Could not set default') })
              }
            >
              Set default
            </Button>
          )}
          <Button variant="ghost" size="sm" onClick={() => setConfirming((c) => !c)}>
            Delete
          </Button>
        </div>
      </div>
      {confirming && (
        <form
          className="mt-3 rounded-md border border-destructive/40 bg-destructive/5 p-3"
          onSubmit={(e) => {
            e.preventDefault()
            del.mutate(vault.id, {
              onSuccess: () => toast.success('Vault deleted'),
              onError: () => toast.error('Delete failed'),
            })
          }}
        >
          <label className="block text-sm text-foreground">
            Type "{vault.name}" to confirm
            <input
              className={inputClass}
              aria-label={`Type ${vault.name} to confirm`}
              value={phrase}
              onChange={(e) => setPhrase(e.target.value)}
            />
          </label>
          <Button className="mt-3" type="submit" variant="destructive" size="sm" disabled={phrase !== vault.name}>
            Delete vault
          </Button>
        </form>
      )}
    </li>
  )
}

import { useState } from 'react'
import { Pencil, Star, Trash2 } from 'lucide-react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from '@/settings/account/section-card'
import { useVaults, useUpdateVault, type Vault } from '@/api/queries'
import { DeleteVaultDialog } from './delete-vault-dialog'

const inputClass =
  'block w-full rounded-md border border-input bg-card px-2 py-1 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export function ActiveVaultsSection() {
  const { data: vaults, isLoading } = useVaults()
  const [deleteTarget, setDeleteTarget] = useState<Vault | null>(null)

  return (
    <SettingsSectionCard title="Vaults" description="Rename, set a default, or delete your vaults.">
      {isLoading && <p className="text-sm text-muted-foreground">Loading…</p>}
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b border-border text-left text-xs text-muted-foreground">
            <th className="py-2 font-medium">Name</th>
            <th className="py-2 text-right font-medium">Files</th>
            <th className="py-2 text-right font-medium">Attachments</th>
            <th className="py-2" aria-label="Actions" />
          </tr>
        </thead>
        <tbody className="divide-y divide-border">
          {(vaults ?? []).map((v) => (
            <VaultRow key={v.id} vault={v} onDelete={() => setDeleteTarget(v)} />
          ))}
          {!isLoading && (vaults ?? []).length === 0 && (
            <tr>
              <td colSpan={4} className="py-3 text-muted-foreground">
                No vaults yet.
              </td>
            </tr>
          )}
        </tbody>
      </table>

      {deleteTarget && (
        <DeleteVaultDialog
          vault={deleteTarget}
          open={deleteTarget !== null}
          onOpenChange={(open) => !open && setDeleteTarget(null)}
        />
      )}
    </SettingsSectionCard>
  )
}

function VaultRow({ vault, onDelete }: { vault: Vault; onDelete: () => void }) {
  const update = useUpdateVault()
  const [renaming, setRenaming] = useState(false)
  const [name, setName] = useState(vault.name)

  function saveName() {
    const next = name.trim()
    if (next && next !== vault.name) {
      update.mutate({ id: vault.id, name: next }, { onError: () => toast.error('Rename failed') })
    }
    setRenaming(false)
  }

  return (
    <tr>
      <td className="py-3">
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
          <span className="flex items-center gap-2">
            <span className="font-medium text-foreground">{vault.name}</span>
            {vault.is_default && (
              <span className="rounded bg-muted px-2 py-0.5 text-xs text-muted-foreground">Default</span>
            )}
          </span>
        )}
      </td>
      <td className="py-3 text-right tabular-nums text-muted-foreground">{vault.note_count ?? 0}</td>
      <td className="py-3 text-right tabular-nums text-muted-foreground">{vault.attachment_count ?? 0}</td>
      <td className="py-3">
        <span className="flex items-center justify-end gap-1">
          {!vault.is_default && (
            <Button
              variant="ghost"
              size="icon-sm"
              title={`Set ${vault.name} as default`}
              aria-label={`Set ${vault.name} as default`}
              onClick={() =>
                update.mutate(
                  { id: vault.id, is_default: true },
                  { onError: () => toast.error('Could not set default') },
                )
              }
            >
              <Star />
            </Button>
          )}
          <Button
            variant="ghost"
            size="icon-sm"
            title={`Rename ${vault.name}`}
            aria-label={`Rename ${vault.name}`}
            onClick={() => setRenaming(true)}
          >
            <Pencil />
          </Button>
          <Button
            variant="destructive"
            size="icon-sm"
            title={`Delete ${vault.name}`}
            aria-label={`Delete ${vault.name}`}
            onClick={onDelete}
          >
            <Trash2 />
          </Button>
        </span>
      </td>
    </tr>
  )
}

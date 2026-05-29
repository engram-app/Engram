import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { SettingsSectionCard } from '@/settings/account/section-card'
import {
  useDeletedVaults,
  useVaults,
  useRestoreVault,
  usePurgeVault,
  useBillingConfig,
  type Vault,
} from '@/api/queries'

export function DeletedVaultsSection() {
  const { data: deleted } = useDeletedVaults()
  if (!deleted || deleted.length === 0) return null

  return (
    <SettingsSectionCard
      title="Recently deleted"
      description="Deleted vaults are kept for 30 days. Restore them, or remove them permanently."
    >
      <ul className="divide-y divide-border">
        {deleted.map((v) => (
          <DeletedRow key={v.id} vault={v} />
        ))}
      </ul>
    </SettingsSectionCard>
  )
}

function DeletedRow({ vault }: { vault: Vault }) {
  const { data: active } = useVaults()
  const { data: billing } = useBillingConfig()
  const restore = useRestoreVault()
  const purge = usePurgeVault()

  const cap = billing?.vaults_cap ?? Infinity
  const activeCount = active?.length ?? 0
  const overCap = activeCount >= cap
  const purgeDate = vault.purge_at ? new Date(vault.purge_at).toLocaleDateString() : null

  const highlightId = new URLSearchParams(window.location.search).get('highlight')
  const highlighted = highlightId === String(vault.id)

  return (
    <li
      data-highlighted={highlighted}
      className={`flex items-center justify-between gap-3 py-3 ${
        highlighted ? 'rounded-md bg-accent/40 ring-1 ring-ring' : ''
      }`}
    >
      <div>
        <p className="text-sm font-medium text-foreground">{vault.name}</p>
        {purgeDate && <p className="text-xs text-muted-foreground">Purges {purgeDate}</p>}
      </div>
      <div className="flex items-center gap-2">
        <Button
          variant="outline"
          size="sm"
          disabled={overCap || restore.isPending}
          title={
            overCap
              ? 'Restoring would exceed your vault limit. Upgrade or delete another vault first.'
              : undefined
          }
          onClick={() =>
            restore.mutate(vault.id, {
              onSuccess: () => toast.success('Vault restored'),
              onError: () => toast.error('Could not restore (vault limit reached?)'),
            })
          }
        >
          Restore
        </Button>
        <Button
          variant="destructive"
          size="sm"
          disabled={purge.isPending}
          onClick={() => {
            if (window.confirm(`Permanently delete "${vault.name}"? This cannot be undone.`)) {
              purge.mutate(vault.id, {
                onSuccess: () => toast.success('Vault permanently deleted'),
                onError: () => toast.error('Could not delete'),
              })
            }
          }}
        >
          Delete permanently
        </Button>
      </div>
    </li>
  )
}

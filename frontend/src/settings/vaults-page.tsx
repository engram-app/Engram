import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { VaultCreateForm } from '@/components/vault-create-form'
import { ActiveVaultsSection } from './vaults/active-vaults-section'
import { DeletedVaultsSection } from './vaults/deleted-vaults-section'

export default function VaultsPage() {
  const [open, setOpen] = useState(false)

  return (
    <article className="space-y-6">
      <header className="flex items-start justify-between">
        <div>
          <h1 className="text-xl font-semibold text-foreground">Vaults</h1>
          <p className="mt-1 text-sm text-muted-foreground">Manage, create, and recover your vaults.</p>
        </div>
        <Button onClick={() => setOpen((o) => !o)}>New vault</Button>
      </header>

      {open && (
        <section className="rounded-lg border border-border bg-card p-4">
          <VaultCreateForm
            autoFocus
            showCancel
            onCancel={() => setOpen(false)}
            onCreated={() => setOpen(false)}
          />
        </section>
      )}

      <ActiveVaultsSection />
      <DeletedVaultsSection />
    </article>
  )
}

import { useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import { useCreateVault } from '@/api/queries'
import { ActiveVaultsSection } from './vaults/active-vaults-section'
import { DeletedVaultsSection } from './vaults/deleted-vaults-section'

const inputClass =
  'mt-1 block w-full rounded-md border border-input bg-card px-3 py-2 text-sm text-foreground focus:border-ring focus:outline-none focus:ring-1 focus:ring-ring'

export default function VaultsPage() {
  const create = useCreateVault()
  const [open, setOpen] = useState(false)
  const [name, setName] = useState('')

  function submit(e: React.FormEvent) {
    e.preventDefault()
    const next = name.trim()
    if (!next) return
    create.mutate(
      { name: next },
      {
        onSuccess: () => {
          toast.success('Vault created')
          setName('')
          setOpen(false)
        },
        onError: () => toast.error('Could not create vault (limit reached?)'),
      },
    )
  }

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
        <form className="rounded-lg border border-border bg-card p-4" onSubmit={submit}>
          <label className="block text-sm font-medium text-foreground">
            Vault name
            <input className={inputClass} aria-label="Vault name" value={name} onChange={(e) => setName(e.target.value)} />
          </label>
          <div className="mt-3 flex gap-2">
            <Button type="submit" size="sm" disabled={create.isPending}>
              Create
            </Button>
            <Button type="button" variant="ghost" size="sm" onClick={() => setOpen(false)}>
              Cancel
            </Button>
          </div>
        </form>
      )}

      <ActiveVaultsSection />
      <DeletedVaultsSection />
    </article>
  )
}

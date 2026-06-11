import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle } from '../components/ui/dialog'
import { VaultCreateForm } from '../components/vault-create-form'

interface Props {
  onCreated: (vaultId: string) => void
}

export function CreateFirstVaultModal({ onCreated }: Props) {
  return (
    <Dialog open>
      <DialogContent
        className="sm:max-w-md"
        showCloseButton={false}
        onEscapeKeyDown={(e) => e.preventDefault()}
        onPointerDownOutside={(e) => e.preventDefault()}
        onInteractOutside={(e) => e.preventDefault()}
      >
        <DialogHeader>
          <DialogTitle>Create your first vault</DialogTitle>
          <DialogDescription>
            A vault holds your notes. You can rename it or add more later.
          </DialogDescription>
        </DialogHeader>
        <VaultCreateForm autoFocus submitLabel="Create vault" onCreated={onCreated} />
      </DialogContent>
    </Dialog>
  )
}

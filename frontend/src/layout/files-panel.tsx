import { ScrollArea } from '@/components/ui/scroll-area'
import { FolderTreeProvider } from './folder-tree-context'
import FolderActions from './folder-actions'
import VaultSwitcher from './vault-switcher'
import FolderTree from '../viewer/folder-tree'
import { useDemoVaultOptional } from '../onboarding/tour/demo-vault-provider'

export default function FilesPanel() {
  const demoActive = useDemoVaultOptional()?.active === true
  return (
    <FolderTreeProvider>
      <div className="flex h-full flex-col">
        <header className="flex shrink-0 items-center border-b border-border px-3 py-2">
          <h2 className="text-xs font-semibold uppercase tracking-wide text-muted-foreground">Files</h2>
        </header>
        <ScrollArea className="flex-1" data-tour="folder-tree">
          <FolderTree />
        </ScrollArea>
        <FolderActions />
        <section className="relative">
          <VaultSwitcher />
          {demoActive && (
            <div
              data-tour="sidebar-vaults"
              aria-hidden
              className="pointer-events-none absolute inset-x-0 bottom-0 -top-24"
            />
          )}
        </section>
      </div>
    </FolderTreeProvider>
  )
}

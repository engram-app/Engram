import { Lock } from 'lucide-react'

import { useUpgradeDialog } from '@/billing/upgrade-dialog-provider'

// Free tier: rendered in place of `<img>` / `<embed>` for attachment embeds
// (`![[image.png]]`). Click surfaces the global UpgradeRequiredDialog so the
// reason → copy mapping in `limit-copy.ts` stays the single source of truth.
export function AttachmentFallback({ filename }: { filename: string }) {
  const { showUpgrade } = useUpgradeDialog()
  return (
    <button
      type="button"
      data-testid="attachment-fallback-lock"
      onClick={() => showUpgrade('attachments_disabled')}
      title="Upgrade to view attachments"
      className="my-2 inline-flex items-center gap-2 rounded border border-dashed border-border px-3 py-2 text-sm text-muted-foreground hover:bg-muted"
    >
      <Lock className="h-4 w-4" aria-hidden="true" />
      <span>{filename}</span>
    </button>
  )
}

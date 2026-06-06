import { Button } from '@/components/ui/button'
import { useCancelSubscription } from '../api/queries'
import type { SubscriptionDetail } from '../api/queries'
import { toast } from 'sonner'

interface CancelPanelProps {
  detail: SubscriptionDetail
  onClose: () => void
}

export default function CancelPanel({ detail, onClose }: CancelPanelProps) {
  const cancel = useCancelSubscription()

  // next_billed_at is the natural cancel-effective date when canceling
  // at-period-end. Falls back to a generic line if the backend has not yet
  // populated it (newly-subscribed user mid-webhook-sync).
  const effective = detail.next_billed_at
    ? new Date(detail.next_billed_at).toLocaleDateString()
    : null

  async function confirm() {
    try {
      await cancel.mutateAsync()
      toast.success('Subscription scheduled to cancel.')
      onClose()
    } catch {
      toast.error('Could not cancel subscription. Please try again.')
    }
  }

  return (
    <section
      role="region"
      aria-label="Cancel subscription"
      className="space-y-4 pt-2"
    >
      <header>
        <h2 className="text-base font-semibold text-foreground">Cancel subscription</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          {effective ? (
            <>
              You'll keep Pro access until <strong>{effective}</strong>, then drop to Free.
            </>
          ) : (
            <>You'll keep paid access through the end of your current billing period.</>
          )}
        </p>
      </header>
      <ul className="list-disc space-y-1 pl-5 text-sm text-muted-foreground">
        <li>Your notes stay. Sync still works for vaults within Free limits.</li>
        <li>Vaults or notes that exceed Free limits become read-only.</li>
        <li>You can reverse this any time before the effective date.</li>
      </ul>
      <div className="flex gap-2">
        <Button
          variant="destructive"
          onClick={confirm}
          disabled={cancel.isPending}
        >
          Cancel at period end
        </Button>
        <Button variant="ghost" onClick={onClose} disabled={cancel.isPending}>
          Keep my subscription
        </Button>
      </div>
    </section>
  )
}

import type { SubscriptionDetail } from '../api/queries'

const ACTION_LABELS: Record<string, string> = {
  cancel: 'Your plan cancels',
  pause: 'Your plan pauses',
  resume: 'Your plan resumes',
}

export default function PendingChangeBanner({
  scheduledChange,
}: {
  scheduledChange: SubscriptionDetail['scheduled_change']
}) {
  if (!scheduledChange) return null

  const label = ACTION_LABELS[scheduledChange.action] ?? 'Your plan changes'
  const date = new Date(scheduledChange.effective_at).toLocaleDateString()

  return (
    <aside role="status" className="rounded-lg border border-border bg-secondary/50 p-4 text-sm">
      <p className="font-medium text-foreground">
        {label} on {date}
      </p>
    </aside>
  )
}

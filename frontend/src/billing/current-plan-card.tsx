import type { ReactNode } from 'react'
import type { BillingStatus } from '../api/queries'

const TIER_LABELS: Record<BillingStatus['tier'], string> = {
  free: 'Free',
  none: 'No Plan',
  trial: 'Free Trial',
  starter: 'Starter',
  pro: 'Pro',
}

export default function CurrentPlanCard({
  billing,
  children,
}: {
  billing: BillingStatus
  children?: ReactNode
}) {
  const sub = billing.subscription
  const canceled = sub?.status === 'canceled'
  const trialing = sub?.status === 'trialing'
  const periodEnd = sub?.current_period_end
    ? new Date(sub.current_period_end).toLocaleDateString()
    : null
  // A canceled subscription keeps access until the period ends, so the same
  // date means "renews" while live and "access ends" once cancellation is set.
  const periodLabel = canceled ? 'Access ends on' : 'Renews on'

  return (
    <section className="space-y-4 rounded-lg border border-border bg-card p-6">
      <header className="flex items-center justify-between">
        <h2 className="text-lg font-semibold text-foreground">Current Plan</h2>
        <span className="rounded-full bg-secondary px-3 py-1 text-sm font-medium text-secondary-foreground">
          {TIER_LABELS[billing.tier]}
        </span>
      </header>

      {trialing && billing.trial_days_remaining > 0 && (
        <p className="text-sm text-muted-foreground">
          {billing.trial_days_remaining} days remaining in your free trial.
        </p>
      )}

      {sub && (
        <dl className="grid grid-cols-2 gap-4 text-sm">
          <dt className="text-muted-foreground">Status</dt>
          <dd className="font-medium capitalize">{sub.status.replace('_', ' ')}</dd>
          {periodEnd && (
            <>
              <dt className="text-muted-foreground">{periodLabel}</dt>
              <dd className="font-medium">{periodEnd}</dd>
            </>
          )}
        </dl>
      )}

      {children && <div className="border-t border-border pt-4">{children}</div>}
    </section>
  )
}

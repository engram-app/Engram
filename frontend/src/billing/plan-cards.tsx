import { cn } from '@/lib/utils'
import type { BillingCadence } from '../api/queries'

export type PlanTier = 'starter' | 'pro'

export interface PlanCardCatalog {
  name: string
  monthlyPrice: number
  annualPrice: number
  features: string[]
}

// Single catalog source-of-truth: both onboarding (trial signup) and the
// change-plan panel read display prices from here. Keep in sync with the
// pricing model lock (Free / $7 / $14 monthly + $70/$140 annual — see
// memory project_pricing_model). Updating Paddle prices means updating here.
export const PLAN_CATALOG: Record<PlanTier, PlanCardCatalog> = {
  starter: {
    name: 'Starter',
    monthlyPrice: 7,
    annualPrice: 70,
    features: ['5 vaults', 'Unlimited devices', '3 GB attachments', '500 AI queries/day'],
  },
  pro: {
    name: 'Pro',
    monthlyPrice: 14,
    annualPrice: 140,
    features: [
      '15 vaults',
      'Unlimited devices',
      '15 GB attachments',
      'Unlimited AI',
      'Smart retrieval (coming)',
    ],
  },
}

export function CadenceToggle({
  cadence,
  onChange,
}: {
  cadence: BillingCadence
  onChange: (next: BillingCadence) => void
}) {
  return (
    <div role="radiogroup" aria-label="Billing cadence" className="flex justify-center">
      <div className="inline-flex rounded-full border border-border bg-muted p-1 text-sm">
        <button
          role="radio"
          aria-checked={cadence === 'monthly'}
          onClick={() => onChange('monthly')}
          className={cn(
            'rounded-full px-4 py-1.5 font-medium transition',
            cadence === 'monthly'
              ? 'bg-background text-foreground shadow-sm'
              : 'text-muted-foreground hover:text-foreground',
          )}
        >
          Monthly
        </button>
        <button
          role="radio"
          aria-checked={cadence === 'annual'}
          onClick={() => onChange('annual')}
          className={cn(
            'rounded-full px-4 py-1.5 font-medium transition',
            cadence === 'annual'
              ? 'bg-background text-foreground shadow-sm'
              : 'text-muted-foreground hover:text-foreground',
          )}
        >
          Annual <span className="ml-1 text-xs text-primary">save 17%</span>
        </button>
      </div>
    </div>
  )
}

interface PlanCardProps {
  name: string
  cadence: BillingCadence
  monthlyPrice: number
  annualPrice: number
  features: string[]
  tier: PlanTier
  onAction: (tier: PlanTier) => void
  disabled?: boolean
  // Visual states — pick at most one (current beats selected which beats
  // recommended). Only one card per panel should render any of these.
  recommended?: boolean
  selected?: boolean
  current?: boolean
  ctaLabel?: string
  // ctaSubLabel is shown under the CTA only on the selected card — used by
  // PlanChangePanel to surface inline proration without a separate strip.
  ctaSubLabel?: string
}

export function PlanCard({
  name,
  cadence,
  monthlyPrice,
  annualPrice,
  features,
  tier,
  onAction,
  disabled = false,
  recommended = false,
  selected = false,
  current = false,
  ctaLabel = 'Start free trial',
  ctaSubLabel,
}: PlanCardProps) {
  const price = cadence === 'monthly' ? `$${monthlyPrice}/mo` : `$${annualPrice}/yr`
  const subPrice =
    cadence === 'annual'
      ? `$${(annualPrice / 12).toFixed(2)}/mo billed yearly`
      : `$${monthlyPrice * 12}/yr billed monthly`

  // Effective state precedence — current beats selected beats recommended.
  // Avoids the "everything is highlighted" failure mode if a parent passes
  // multiple truthy flags by mistake.
  const state: 'current' | 'selected' | 'recommended' | 'idle' = current
    ? 'current'
    : selected
      ? 'selected'
      : recommended
        ? 'recommended'
        : 'idle'

  const badgeText =
    state === 'current' ? 'Your plan' : state === 'recommended' ? 'Most popular' : null

  return (
    <li
      className={cn(
        'relative flex flex-col gap-4 rounded-lg border bg-card p-6 transition duration-150',
        state === 'idle' && 'border-border hover:-translate-y-0.5 hover:border-primary/60',
        state === 'recommended' &&
          'border-primary ring-1 ring-primary hover:-translate-y-0.5',
        state === 'selected' &&
          'border-primary ring-2 ring-primary shadow-sm',
        // 'current' reads as "you've got this" — primary accent ring, no
        // muted bg. Diminished-grey treatment made the card feel locked
        // out; this leans into the card visually instead.
        state === 'current' && 'border-primary/60 ring-1 ring-primary/30 shadow-sm',
      )}
    >
      {badgeText && (
        <span
          className="absolute -top-3 left-6 rounded-full bg-primary px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wide text-primary-foreground"
        >
          {badgeText}
        </span>
      )}
      <h3 className="text-lg font-semibold">{name}</h3>
      <p className="text-2xl font-bold">{price}</p>
      <p className="-mt-3 text-xs text-muted-foreground">{subPrice}</p>
      <ul className="flex-1 space-y-1 text-sm text-muted-foreground">
        {features.map((f) => (
          <li key={f} className="flex items-center gap-2">
            <span className="text-primary" aria-hidden="true">
              &#10003;
            </span>
            {f}
          </li>
        ))}
      </ul>
      <div className="flex flex-col gap-1">
        {current ? (
          // Inert positive indicator instead of a disabled button: same
          // height as the CTA so card layout stays consistent, but
          // visually reads as confirmation, not as a denied action.
          <div
            role="status"
            aria-label="Your current plan"
            className="flex w-full items-center justify-center gap-2 rounded-lg border border-primary/40 bg-primary/10 px-4 py-2 text-sm font-medium text-primary"
          >
            <span aria-hidden="true">&#10003;</span>
            <span>You're on this plan</span>
          </div>
        ) : (
          <>
            <button
              onClick={() => onAction(tier)}
              disabled={disabled}
              className={cn(
                'w-full rounded-lg px-4 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-50',
                // recommended (onboarding's Pro) and selected (change-plan's
                // chosen target) get filled-primary CTA so the actionable
                // card has weight. idle stays a clean outline.
                state === 'recommended' || state === 'selected'
                  ? 'bg-primary text-primary-foreground hover:bg-primary/90'
                  : 'border border-input bg-transparent text-foreground hover:bg-accent',
              )}
            >
              {ctaLabel}
            </button>
            {selected && ctaSubLabel && (
              <p className="text-center text-xs text-muted-foreground">{ctaSubLabel}</p>
            )}
          </>
        )}
      </div>
    </li>
  )
}

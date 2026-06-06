import { useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import {
  useBillingConfig,
  useBillingSubscriptionDetail,
  useConfirmPlanChange,
  usePlanChangePreview,
  type BillingCadence,
  type BillingStatus,
  type SubscriptionDetail,
} from '../api/queries'
import { CadenceToggle, PLAN_CATALOG, PlanCard, type PlanTier } from './plan-cards'

interface PlanChangePanelProps {
  billing: BillingStatus
  onClose: () => void
}

function formatCents(cents: number | null | undefined): string {
  if (cents === null || cents === undefined) return '—'
  // Paddle returns totals as raw cents (USD only for now). Zero-decimal
  // currencies (JPY/KRW/CLP) would need a separate code path — defer until
  // the proration UI supports non-USD.
  const sign = cents < 0 ? '-' : ''
  const abs = Math.abs(cents)
  return `${sign}$${(abs / 100).toFixed(2)}`
}

function deriveCurrentTier(billing: BillingStatus): PlanTier | null {
  const tier = billing.subscription?.tier
  return tier === 'starter' || tier === 'pro' ? tier : null
}

// Cadence comes from /billing/subscription's billing_cycle.interval; if the
// detail hasn't loaded (or never resolves for sideloaded dev subs), default
// to monthly so the panel still renders. The toggle is the user's lever to
// override regardless.
function deriveCurrentCadence(detail: SubscriptionDetail | undefined): BillingCadence {
  return detail?.billing_cycle?.interval === 'year' ? 'annual' : 'monthly'
}

export default function PlanChangePanel({ billing, onClose }: PlanChangePanelProps) {
  const { data: config } = useBillingConfig()
  const { data: detail } = useBillingSubscriptionDetail(Boolean(billing.subscription))
  const currentTier = deriveCurrentTier(billing)
  const currentCadence = deriveCurrentCadence(detail)
  // Open the toggle on the user's existing cadence so the first card grid
  // they see reflects 'what would change' rather than always-Monthly.
  const [cadence, setCadence] = useState<BillingCadence>(currentCadence)
  const [selectedTier, setSelectedTier] = useState<PlanTier | null>(null)

  const targetPriceId =
    selectedTier && config ? (config.price_ids[selectedTier][cadence] ?? null) : null

  const preview = usePlanChangePreview(targetPriceId)
  const confirm = useConfirmPlanChange()

  if (!config) {
    return (
      <section role="region" aria-label="Change plan" className="py-2">
        <p className="text-sm text-muted-foreground">Loading plan options…</p>
      </section>
    )
  }

  async function onConfirm() {
    if (!targetPriceId) return
    try {
      await confirm.mutateAsync(targetPriceId)
      toast.success('Plan change confirmed.')
      onClose()
    } catch {
      toast.error('Could not change plan. Please try again.')
    }
  }

  return (
    <section role="region" aria-label="Change plan" className="space-y-5 pt-2">

      <header>
        <h2 className="text-base font-semibold text-foreground">Change your plan</h2>
        <p className="mt-2 text-sm text-muted-foreground">
          Proration applies immediately. The selected card shows what'll be charged or credited
          before you confirm.
        </p>
      </header>

      <CadenceToggle
        cadence={cadence}
        onChange={(next) => {
          setCadence(next)
          setSelectedTier(null)
        }}
      />

      <ul className="grid items-stretch gap-4 sm:grid-cols-2">
        {(Object.keys(PLAN_CATALOG) as PlanTier[]).map((tier) => {
          const meta = PLAN_CATALOG[tier]
          // 'Current' only matches when the toggle is on the user's
          // existing cadence — flipping to Annual surfaces Pro again as a
          // selectable upgrade target so monthly→annual is a real path.
          const isCurrent = tier === currentTier && cadence === currentCadence
          const isSelected = tier === selectedTier
          // Visual focal-point hint: when the toggle puts both cards on
          // non-current cadence, the page has TWO selectable cards and
          // neither should auto-highlight. When toggle is on current
          // cadence, exactly one alternative exists — highlight it.
          const availableCount = Object.keys(PLAN_CATALOG).length - (cadence === currentCadence && currentTier ? 1 : 0)
          const isDefaultTarget =
            selectedTier === null && !isCurrent && availableCount === 1
          return (
            <PlanCard
              key={tier}
              name={meta.name}
              cadence={cadence}
              monthlyPrice={meta.monthlyPrice}
              annualPrice={meta.annualPrice}
              features={meta.features}
              tier={tier}
              onAction={(t) => setSelectedTier(t)}
              current={isCurrent}
              selected={isSelected || isDefaultTarget}
              ctaLabel={isSelected ? 'Selected' : 'Select'}
              ctaSubLabel={
                isSelected && preview.isFetching
                  ? 'Loading proration…'
                  : isSelected && preview.data
                    ? formatProration(preview.data)
                    : undefined
              }
            />
          )
        })}
      </ul>

      <div className="flex gap-2">
        <Button
          onClick={onConfirm}
          disabled={
            !selectedTier ||
            !targetPriceId ||
            preview.isFetching ||
            !preview.data ||
            confirm.isPending
          }
        >
          Confirm change
        </Button>
        <Button variant="ghost" onClick={onClose} disabled={confirm.isPending}>
          Cancel
        </Button>
      </div>
    </section>
  )
}

function formatProration(data: {
  immediate_charge_or_credit: number
  new_total: number
  next_billed_at: string
}): string {
  const direction = data.immediate_charge_or_credit > 0 ? 'Charged' : 'Credited'
  const amount = formatCents(Math.abs(data.immediate_charge_or_credit))
  const renewal = new Date(data.next_billed_at).toLocaleDateString()
  return `${direction} ${amount} today; next bill ${formatCents(data.new_total)} on ${renewal}`
}

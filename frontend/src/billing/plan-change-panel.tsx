import { useState } from 'react'
import { toast } from 'sonner'
import { Button } from '@/components/ui/button'
import {
  useBillingConfig,
  useConfirmPlanChange,
  usePlanChangePreview,
  type BillingCadence,
  type BillingStatus,
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

export default function PlanChangePanel({ billing, onClose }: PlanChangePanelProps) {
  const { data: config } = useBillingConfig()
  const [cadence, setCadence] = useState<BillingCadence>('monthly')
  const [selectedTier, setSelectedTier] = useState<PlanTier | null>(null)

  const targetPriceId =
    selectedTier && config ? (config.price_ids[selectedTier][cadence] ?? null) : null

  const preview = usePlanChangePreview(targetPriceId)
  const confirm = useConfirmPlanChange()

  if (!config) {
    return (
      <section
        role="region"
        aria-label="Change plan"
        className="rounded-lg border border-border bg-card p-6"
      >
        <p className="text-sm text-muted-foreground">Loading plan options…</p>
      </section>
    )
  }

  const currentTier = deriveCurrentTier(billing)

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
    <section
      role="region"
      aria-label="Change plan"
      className="space-y-5 rounded-lg border border-border bg-card p-6"
    >
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
          const isCurrent = tier === currentTier
          const isSelected = tier === selectedTier
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
              selected={isSelected}
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

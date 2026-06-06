import { useState } from 'react'
import { toast } from 'sonner'
import { RadioGroup } from '@/components/ui/radio-group'
import { Button } from '@/components/ui/button'
import { PricingSelectCardGrid } from '@/components/pricing-select-card-grid'
import { BillingIntervalToggle } from '@/components/billing-interval-toggle'
import {
  useBillingConfig,
  useConfirmPlanChange,
  usePlanChangePreview,
  type BillingCadence,
  type BillingStatus,
} from '../api/queries'

interface PlanChangePanelProps {
  billing: BillingStatus
  onClose: () => void
}

// Display catalog — mirrors the live-paddle prices in BillingConfig.price_ids.
// Hardcoded display strings are fine here: PricingSelectCardGrid renders raw
// pre-formatted strings (see paddle-types.ts PriceData), no PricePreview SDK
// call needed. If prices ever change in Paddle, update here and in PlanCard
// (billing-page.tsx) — both share the same source-of-truth catalog.
const CATALOG = {
  starter: {
    name: 'Starter',
    description: '5 vaults · 3 GB · 500 AI queries/day',
    prices: {
      monthly: { total: '$7', interval: 'month' },
      annual: { total: '$70', interval: 'year' },
    },
  },
  pro: {
    name: 'Pro',
    description: '15 vaults · 15 GB · Unlimited AI',
    prices: {
      monthly: { total: '$14', interval: 'month' },
      annual: { total: '$140', interval: 'year' },
    },
  },
} as const

type Tier = keyof typeof CATALOG

function formatCents(cents: number | null | undefined): string {
  if (cents === null || cents === undefined) return '—'
  // Paddle returns totals in lowest-unit decimal strings or integers; we treat
  // them as raw cents here. JPY/KRW/CLP zero-decimal currencies would need a
  // separate code path — defer that until the proration UI supports non-USD.
  const sign = cents < 0 ? '-' : ''
  const abs = Math.abs(cents)
  return `${sign}$${(abs / 100).toFixed(2)}`
}

export default function PlanChangePanel({ billing, onClose }: PlanChangePanelProps) {
  const { data: config } = useBillingConfig()
  const [cadence, setCadence] = useState<BillingCadence>(
    billing.subscription?.tier === 'pro' || billing.subscription?.tier === 'starter' ? 'monthly' : 'monthly',
  )
  const [targetPriceId, setTargetPriceId] = useState<string | null>(null)
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

  const currentPriceId = priceIdForCurrent(config.price_ids, billing.subscription?.tier, cadence)

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
          Proration applies immediately. You can preview the charge or credit before confirming.
        </p>
      </header>

      <BillingIntervalToggle
        intervals={['monthly', 'annual']}
        value={cadence}
        onValueChange={(v) => {
          setCadence(v as BillingCadence)
          setTargetPriceId(null)
        }}
      />

      <RadioGroup
        value={targetPriceId ?? ''}
        onValueChange={setTargetPriceId}
        className="grid grid-cols-1 gap-3 sm:grid-cols-2"
      >
        {(Object.keys(CATALOG) as Tier[]).map((tier) => {
          const priceId = config.price_ids[tier][cadence]
          const meta = CATALOG[tier]
          return (
            <PricingSelectCardGrid
              key={priceId}
              priceId={priceId}
              name={meta.name}
              description={meta.description}
              priceData={meta.prices[cadence]}
              isCurrent={priceId !== null && priceId === currentPriceId}
              currentPlanLabel="Current plan"
            />
          )
        })}
      </RadioGroup>

      {targetPriceId && preview.isFetching && (
        <div role="status" className="h-20 animate-pulse rounded-md bg-muted/50" />
      )}

      {targetPriceId && preview.data && !preview.isFetching && (
        <PreviewLines
          credit={preview.data.immediate_charge_or_credit < 0 ? -preview.data.immediate_charge_or_credit : 0}
          charge={preview.data.immediate_charge_or_credit > 0 ? preview.data.immediate_charge_or_credit : 0}
          newTotal={preview.data.new_total}
          nextBilledAt={preview.data.next_billed_at}
        />
      )}

      <div className="flex gap-2">
        <Button
          onClick={onConfirm}
          disabled={!targetPriceId || preview.isFetching || confirm.isPending || !preview.data}
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

function PreviewLines({
  credit,
  charge,
  newTotal,
  nextBilledAt,
}: {
  credit: number
  charge: number
  newTotal: number
  nextBilledAt: string
}) {
  const renewalDate = new Date(nextBilledAt).toLocaleDateString()
  return (
    <dl
      role="status"
      aria-label="Plan change preview"
      className="grid gap-2 rounded-md border border-border bg-muted/30 p-4 text-sm"
    >
      {charge > 0 && (
        <div className="flex justify-between">
          <dt className="text-muted-foreground">Charged today</dt>
          <dd className="font-medium text-foreground">{formatCents(charge)}</dd>
        </div>
      )}
      {credit > 0 && (
        <div className="flex justify-between">
          <dt className="text-muted-foreground">Credited today</dt>
          <dd className="font-medium text-foreground">{formatCents(credit)}</dd>
        </div>
      )}
      <div className="flex justify-between">
        <dt className="text-muted-foreground">Next bill on {renewalDate}</dt>
        <dd className="font-medium text-foreground">{formatCents(newTotal)}</dd>
      </div>
    </dl>
  )
}

function priceIdForCurrent(
  priceIds: { starter: { monthly: string; annual: string }; pro: { monthly: string; annual: string } },
  tier: string | undefined,
  cadence: BillingCadence,
): string | null {
  if (tier === 'starter' || tier === 'pro') return priceIds[tier][cadence]
  return null
}

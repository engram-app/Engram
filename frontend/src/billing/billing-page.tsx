import { useEffect, useState } from 'react'
import { initializePaddle, type Paddle } from '@paddle/paddle-js'
import { useBillingStatus, useBillingConfig, type BillingConfig } from '../api/queries'
import { api } from '../api/client'
import { cn } from '@/lib/utils'

const TIER_LABELS = {
  free: 'Free',
  none: 'No Plan',
  trial: 'Free Trial',
  starter: 'Starter',
  pro: 'Pro',
} as const

export default function BillingPage({ hideHeading = false }: { hideHeading?: boolean }) {
  const { data: billing, isLoading } = useBillingStatus()
  const { data: config } = useBillingConfig()
  const [paddle, setPaddle] = useState<Paddle>()

  useEffect(() => {
    if (!config) return
    initializePaddle({
      token: config.client_token,
      environment: config.environment,
      checkout: { settings: { displayMode: 'overlay', theme: 'light', locale: 'en' } },
    }).then((instance) => {
      if (instance) setPaddle(instance)
    })
  }, [config])

  if (isLoading || !billing) {
    return <p className="text-muted-foreground">Loading billing info...</p>
  }

  const needsSubscription = !billing.active
  const isTrial = billing.subscription?.status === 'trialing'
  const checkoutReady = Boolean(paddle && config)

  return (
    <article className="mx-auto max-w-2xl space-y-8">
      {!hideHeading && <h1 className="text-2xl font-bold text-foreground">Billing</h1>}

      {!hideHeading && (
        <section className="space-y-4 rounded-lg border border-border bg-card p-6">
          <header className="flex items-center justify-between">
            <h2 className="text-lg font-semibold text-foreground">Current Plan</h2>
            <span className="rounded-full bg-secondary px-3 py-1 text-sm font-medium text-secondary-foreground">
              {TIER_LABELS[billing.tier]}
            </span>
          </header>

          {needsSubscription && (
            <p className="text-sm text-muted-foreground">
              Choose a plan below to start your 7-day free trial. A card is required but you
              won't be charged until the trial ends.
            </p>
          )}

          {isTrial && billing.trial_days_remaining > 0 && (
            <p className="text-sm text-muted-foreground">
              {billing.trial_days_remaining} days remaining in your free trial.
            </p>
          )}

          {billing.subscription && (
            <dl className="grid grid-cols-2 gap-4 text-sm">
              <dt className="text-muted-foreground">Status</dt>
              <dd className="font-medium capitalize">{billing.subscription.status.replace('_', ' ')}</dd>
              {billing.subscription.current_period_end && (
                <>
                  <dt className="text-muted-foreground">Current period ends</dt>
                  <dd className="font-medium">
                    {new Date(billing.subscription.current_period_end).toLocaleDateString()}
                  </dd>
                </>
              )}
            </dl>
          )}
        </section>
      )}

      {needsSubscription && (
        <section className="space-y-4">
          {!hideHeading && (
            <>
              <h2 className="text-lg font-semibold text-foreground">Choose a Plan</h2>
              <p className="text-sm text-muted-foreground">Both plans include a 7-day free trial.</p>
            </>
          )}
          <ul className="grid items-stretch gap-4 sm:grid-cols-2">
            <PlanCard
              name="Starter"
              price="$5/mo"
              features={['10 GB storage', '5 devices', 'Standard search']}
              tier="starter"
              paddle={paddle}
              config={config}
              disabled={!checkoutReady}
            />
            <PlanCard
              name="Pro"
              price="$10/mo"
              features={['50 GB storage', 'Unlimited devices', '2x search rate']}
              tier="pro"
              paddle={paddle}
              config={config}
              disabled={!checkoutReady}
              recommended
            />
          </ul>
        </section>
      )}

      {billing.subscription && billing.subscription.status !== 'canceled' && (
        <section>
          <button
            onClick={handlePortal}
            className="text-sm text-primary underline hover:text-primary/80"
          >
            Manage subscription
          </button>
        </section>
      )}
    </article>
  )
}

function PlanCard({
  name,
  price,
  features,
  tier,
  paddle,
  config,
  disabled,
  recommended = false,
}: {
  name: string
  price: string
  features: string[]
  tier: 'starter' | 'pro'
  paddle: Paddle | undefined
  config: BillingConfig | undefined
  disabled: boolean
  recommended?: boolean
}) {
  function handleCheckout() {
    if (!paddle || !config) return
    paddle.Checkout.open({
      items: [{ priceId: config.price_ids[tier], quantity: 1 }],
      customer: { email: config.customer_email },
      customData: config.custom_data,
      settings: {
        successUrl: `${window.location.origin}/billing?status=success`,
      },
    })
  }

  return (
    <li
      className={cn(
        'relative flex flex-col gap-4 rounded-lg border bg-card p-6 transition duration-150 hover:-translate-y-0.5',
        recommended
          ? 'border-primary ring-1 ring-primary'
          : 'border-border hover:border-primary/60',
      )}
    >
      {recommended && (
        <span className="absolute -top-3 left-6 rounded-full bg-primary px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wide text-primary-foreground">
          Most popular
        </span>
      )}
      <h3 className="text-lg font-semibold">{name}</h3>
      <p className="text-2xl font-bold">{price}</p>
      <ul className="flex-1 space-y-1 text-sm text-muted-foreground">
        {features.map((f) => (
          <li key={f} className="flex items-center gap-2">
            <span className="text-primary" aria-hidden="true">&#10003;</span>
            {f}
          </li>
        ))}
      </ul>
      <button
        onClick={handleCheckout}
        disabled={disabled}
        className={cn(
          'w-full rounded-lg px-4 py-2 text-sm font-medium transition disabled:cursor-not-allowed disabled:opacity-50',
          recommended
            ? 'bg-primary text-primary-foreground hover:bg-primary/90'
            : 'border border-input bg-transparent text-foreground hover:bg-accent',
        )}
      >
        Start free trial
      </button>
    </li>
  )
}

async function handlePortal() {
  const { url } = await api.get<{ url: string }>('/billing/portal')
  window.location.href = url
}

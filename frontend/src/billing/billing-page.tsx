import { useBillingStatus } from '../api/queries'
import { api } from '../api/client'

const TIER_LABELS = {
  none: 'No Plan',
  trial: 'Free Trial',
  starter: 'Starter',
  pro: 'Pro',
} as const

export default function BillingPage() {
  const { data: billing, isLoading } = useBillingStatus()

  if (isLoading || !billing) {
    return <p className="text-gray-500 dark:text-gray-400">Loading billing info...</p>
  }

  const needsSubscription = billing.tier === 'none'
  const isTrial = billing.subscription?.status === 'trialing'

  return (
    <article className="mx-auto max-w-2xl space-y-8">
      <h1 className="text-2xl font-bold text-gray-900 dark:text-gray-100">Billing</h1>

      <section className="rounded-lg border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-6 space-y-4">
        <header className="flex items-center justify-between">
          <h2 className="text-lg font-semibold text-gray-800 dark:text-gray-200">Current Plan</h2>
          <span className="rounded-full bg-blue-100 dark:bg-blue-950 px-3 py-1 text-sm font-medium text-blue-800 dark:text-blue-200">
            {TIER_LABELS[billing.tier]}
          </span>
        </header>

        {needsSubscription && (
          <p className="text-sm text-gray-600 dark:text-gray-300">
            Choose a plan below to start your 7-day free trial. A card is required but you
            won't be charged until the trial ends.
          </p>
        )}

        {isTrial && billing.trial_days_remaining > 0 && (
          <p className="text-sm text-gray-600 dark:text-gray-300">
            {billing.trial_days_remaining} days remaining in your free trial.
          </p>
        )}

        {billing.subscription && (
          <dl className="grid grid-cols-2 gap-4 text-sm">
            <dt className="text-gray-500 dark:text-gray-400">Status</dt>
            <dd className="font-medium capitalize">{billing.subscription.status.replace('_', ' ')}</dd>
            {billing.subscription.current_period_end && (
              <>
                <dt className="text-gray-500 dark:text-gray-400">Current period ends</dt>
                <dd className="font-medium">
                  {new Date(billing.subscription.current_period_end).toLocaleDateString()}
                </dd>
              </>
            )}
          </dl>
        )}
      </section>

      {needsSubscription && (
        <section className="space-y-4">
          <h2 className="text-lg font-semibold text-gray-800 dark:text-gray-200">Choose a Plan</h2>
          <p className="text-sm text-gray-500 dark:text-gray-400">Both plans include a 7-day free trial.</p>
          <ul className="grid gap-4 sm:grid-cols-2">
            <PlanCard
              name="Starter"
              price="$5/mo"
              features={['10 GB storage', '5 devices', 'Standard search']}
              tier="starter"
            />
            <PlanCard
              name="Pro"
              price="$10/mo"
              features={['50 GB storage', 'Unlimited devices', '2x search rate']}
              tier="pro"
            />
          </ul>
        </section>
      )}

      {billing.subscription && billing.subscription.status !== 'canceled' && (
        <section>
          <button
            onClick={handlePortal}
            className="text-sm text-blue-600 underline hover:text-blue-800"
          >
            Manage subscription in Stripe
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
}: {
  name: string
  price: string
  features: string[]
  tier: 'starter' | 'pro'
}) {
  async function handleCheckout() {
    const { url } = await api.post<{ url: string }>('/billing/checkout-session', { tier })
    window.location.href = url
  }

  return (
    <li className="rounded-lg border border-gray-200 dark:border-gray-800 bg-white dark:bg-gray-900 p-6 space-y-4">
      <h3 className="text-lg font-semibold">{name}</h3>
      <p className="text-2xl font-bold">{price}</p>
      <ul className="space-y-1 text-sm text-gray-600 dark:text-gray-300">
        {features.map((f) => (
          <li key={f}>&#10003; {f}</li>
        ))}
      </ul>
      <button
        onClick={handleCheckout}
        className="w-full rounded-lg bg-blue-600 px-4 py-2 text-sm font-medium text-white hover:bg-blue-700"
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

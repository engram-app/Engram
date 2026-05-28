import { useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { CheckoutEventNames, initializePaddle, type Paddle } from '@paddle/paddle-js'
import { toast } from 'sonner'
import {
  useBillingStatus,
  useBillingConfig,
  useBillingSubscriptionDetail,
  useBillingHistory,
  type BillingConfig,
  type OnboardingStatus,
} from '../api/queries'
import { api } from '../api/client'
import { useTheme } from '../theme/theme-provider'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import CurrentPlanCard from './current-plan-card'
import PaymentMethodCard from './payment-method-card'
import BillingHistoryTable from './billing-history-table'
import PendingChangeBanner from './pending-change-banner'

async function openPortal(action?: string) {
  try {
    const path = action ? `/billing/portal?action=${action}` : '/billing/portal'
    const { url } = await api.get<{ url: string }>(path)
    window.location.href = url
  } catch {
    toast.error('Could not open the billing portal. Please try again.')
  }
}

async function downloadInvoice(transactionId: string) {
  try {
    const { url } = await api.get<{ url: string }>(`/billing/transactions/${transactionId}/invoice`)
    window.open(url, '_blank', 'noopener')
  } catch {
    toast.error('Could not fetch that invoice. Please try again.')
  }
}

// Paddle confirms checkout client-side (checkout.completed) before its webhook
// reaches our backend and flips the subscription active, so a single refetch
// races the webhook and reads stale state. Poll the onboarding gate until it
// catches up (or we give up), writing each result into the query cache so the
// onboarding redirect fires without a manual reload.
const ACTIVATION_POLL_MS = 2000
const ACTIVATION_POLL_TIMEOUT_MS = 30000

export default function BillingPage({ hideHeading = false }: { hideHeading?: boolean }) {
  const { data: billing, isLoading } = useBillingStatus()
  const { data: config } = useBillingConfig()
  const hasSubscription = Boolean(billing?.subscription)
  const { data: detail } = useBillingSubscriptionDetail(hasSubscription)
  const { data: history } = useBillingHistory(hasSubscription)
  const { resolved } = useTheme()
  const qc = useQueryClient()
  const [paddle, setPaddle] = useState<Paddle>()
  const [activationStuck, setActivationStuck] = useState(false)
  const pollTimer = useRef<ReturnType<typeof setTimeout>>(undefined)
  const activeRef = useRef(true)

  useEffect(() => {
    activeRef.current = true
    return () => {
      activeRef.current = false
      clearTimeout(pollTimer.current)
    }
  }, [])

  useEffect(() => {
    if (!config) return

    function pollUntilActive(deadline: number) {
      clearTimeout(pollTimer.current)
      pollTimer.current = setTimeout(async () => {
        try {
          const status = await api.get<OnboardingStatus>('/onboarding/status')
          if (!activeRef.current) return
          qc.setQueryData(['onboarding', 'status'], status)
          qc.invalidateQueries({ queryKey: ['billing', 'status'] })
          if (status.next_step === 'done') return
        } catch (err) {
          // A transient 401 (token refresh mid-checkout), 429, or 5xx must not
          // kill the poll — log and fall through to retry within the deadline.
          console.error('billing activation poll request failed; retrying', err)
        }
        if (!activeRef.current) return
        if (Date.now() < deadline) {
          pollUntilActive(deadline)
        } else {
          // Paid, but the webhook hasn't flipped us active in time. Surface it
          // rather than silently stranding the user on the plan page.
          console.error('billing activation timed out before subscription became active')
          setActivationStuck(true)
        }
      }, ACTIVATION_POLL_MS)
    }

    initializePaddle({
      token: config.client_token,
      environment: config.environment,
      eventCallback: (event) => {
        if (event.name === CheckoutEventNames.CHECKOUT_COMPLETED) {
          setActivationStuck(false)
          pollUntilActive(Date.now() + ACTIVATION_POLL_TIMEOUT_MS)
        }
      },
      checkout: {
        settings: {
          displayMode: 'overlay',
          theme: resolved === 'dark' ? 'dark' : 'light',
          locale: 'en',
        },
      },
    }).then((instance) => {
      if (instance) setPaddle(instance)
    })
  }, [config, resolved, qc])

  if (isLoading || !billing) {
    return <p className="text-muted-foreground">Loading billing info...</p>
  }

  const needsSubscription = !billing.active
  const checkoutReady = Boolean(paddle && config)

  return (
    <article className="space-y-6">
      {!hideHeading && (
        <header>
          <h1 className="text-xl font-semibold text-foreground">Billing</h1>
          <p className="mt-1 text-sm text-muted-foreground">
            Manage your plan and payment method.
          </p>
        </header>
      )}

      {activationStuck && (
        <div role="alert" className="rounded-lg border border-border bg-card p-4 text-sm">
          <p className="font-medium text-foreground">Payment received — finishing activation</p>
          <p className="mt-1 text-muted-foreground">
            This is taking longer than usual. Refresh the page in a moment; if it persists,
            contact support and we’ll sort it out.
          </p>
        </div>
      )}

      {!hideHeading && <CurrentPlanCard billing={billing} />}

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

      {!hideHeading && billing.subscription && (
        <>
          <PendingChangeBanner scheduledChange={detail?.scheduled_change ?? null} />
          <PaymentMethodCard
            paymentMethod={history?.payment_method ?? null}
            onUpdate={() => openPortal('update_payment')}
          />
          <BillingHistoryTable
            transactions={history?.transactions ?? []}
            onDownload={downloadInvoice}
          />
          <section className="flex flex-wrap gap-3">
            <Button variant="outline" onClick={() => openPortal()}>
              Manage in Paddle
            </Button>
            {billing.subscription.status !== 'canceled' && (
              <Button variant="ghost" onClick={() => openPortal('cancel')}>
                Cancel subscription
              </Button>
            )}
          </section>
        </>
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
        successUrl: `${window.location.origin}/settings/billing?status=success`,
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

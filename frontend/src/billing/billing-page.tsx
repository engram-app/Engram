import { useCallback, useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { CheckoutEventNames, initializePaddle, type Paddle } from '@paddle/paddle-js'
import { toast } from 'sonner'
import {
  useBillingStatus,
  useBillingConfig,
  useBillingSubscriptionDetail,
  useBillingHistory,
  useMe,
  type BillingCadence,
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
import { ActivationOverlay } from './activation-overlay'
import { useSubscriptionActivatedEvents } from './use-subscription-activated-events'

// Window after CHECKOUT_PAYMENT_INITIATED during which we still expect the
// push to arrive promptly. Past this, the overlay shifts into "taking longer
// than usual" copy with Refresh + Contact support affordances. The channel
// listener stays connected — the broadcast may still land.
const COOLDOWN_MS = 15_000

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

interface BillingPageProps {
  hideHeading?: boolean
  onActivated?: (status: OnboardingStatus) => void
}

export default function BillingPage({ hideHeading = false, onActivated }: BillingPageProps) {
  const { data: billing, isLoading } = useBillingStatus()
  const { data: config } = useBillingConfig()
  const { data: me } = useMe()
  const hasSubscription = Boolean(billing?.subscription)
  const { data: detail } = useBillingSubscriptionDetail(hasSubscription)
  const { data: history } = useBillingHistory(hasSubscription)
  const { resolved } = useTheme()
  const qc = useQueryClient()
  const [paddle, setPaddle] = useState<Paddle>()
  // Ref mirror of `paddle` so the eventCallback (captured pre-instance) can
  // call Checkout.close() on CHECKOUT_COMPLETED without re-initializing.
  const paddleRef = useRef<Paddle | undefined>(undefined)
  const [cadence, setCadence] = useState<BillingCadence>('monthly')

  const [overlayVisible, setOverlayVisible] = useState(false)
  const [paymentInitiatedAt, setPaymentInitiatedAt] = useState<number | null>(null)
  const [cooldownActive, setCooldownActive] = useState(false)
  const [activated, setActivated] = useState(false)
  const [transactionId, setTransactionId] = useState<string | null>(null)

  // Latch — onActivated must fire at most once even if the broadcast lands
  // multiple times (e.g. subscription.created followed by subscription.activated
  // on a trial→active flip).
  const onActivatedFiredRef = useRef(false)
  const onActivatedRef = useRef(onActivated)
  onActivatedRef.current = onActivated

  // Cooldown timer — shifts overlay copy to "taking longer than usual"
  // after 15s without a push event. The channel listener stays connected.
  useEffect(() => {
    if (paymentInitiatedAt === null) return
    const t = setTimeout(() => setCooldownActive(true), COOLDOWN_MS)
    return () => clearTimeout(t)
  }, [paymentInitiatedAt])

  // Push handler — Paddle webhook flipped the subscription server-side and
  // the user channel just told us. Refresh local query state and (in
  // onboarding mode) fetch the fresh onboarding/status to decide where to
  // route the user next.
  const handleSubscriptionActivated = useCallback(async () => {
    setActivated(true)
    await qc.invalidateQueries({ queryKey: ['billing', 'status'] })
    await qc.invalidateQueries({ queryKey: ['billing', 'subscription'] })
    await qc.invalidateQueries({ queryKey: ['billing', 'transactions'] })
    await qc.invalidateQueries({ queryKey: ['onboarding', 'status'] })

    if (onActivatedRef.current && !onActivatedFiredRef.current) {
      try {
        const status = await qc.fetchQuery<OnboardingStatus>({
          queryKey: ['onboarding', 'status'],
          queryFn: () => api.get<OnboardingStatus>('/onboarding/status'),
          staleTime: 0,
        })
        if (!onActivatedFiredRef.current) {
          onActivatedFiredRef.current = true
          onActivatedRef.current(status)
        }
      } catch (err) {
        console.error('failed to refetch onboarding/status after activation', err)
      }
    }
  }, [qc])

  useSubscriptionActivatedEvents({
    userId: me?.id ?? null,
    enabled: true,
    onActivated: handleSubscriptionActivated,
  })

  // Mount-time cache check: if the user lands on billing with a cached
  // onboarding status already past 'billing' (paid in another tab, browser-
  // back, refresh), fire onActivated synchronously instead of waiting on
  // a push event. Only meaningful in onboarding mode.
  useEffect(() => {
    if (!onActivatedRef.current) return
    const cached = qc.getQueryData<OnboardingStatus>(['onboarding', 'status'])
    if (cached && cached.next_step !== 'billing' && !onActivatedFiredRef.current) {
      onActivatedFiredRef.current = true
      setActivated(true)
      onActivatedRef.current(cached)
    }
    // mount-only — qc identity is stable, onActivated read via ref.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    if (!config) return
    let cancelled = false
    initializePaddle({
      token: config.client_token,
      environment: config.environment,
      eventCallback: (event) => {
        if (cancelled) return
        switch (event.name) {
          case CheckoutEventNames.CHECKOUT_PAYMENT_INITIATED: {
            const txn = (event.data as { transaction_id?: string } | undefined)?.transaction_id ?? null
            setTransactionId(txn)
            setOverlayVisible(true)
            setPaymentInitiatedAt((prev) => prev ?? Date.now())
            qc.invalidateQueries({ queryKey: ['billing', 'subscription'] })
            qc.invalidateQueries({ queryKey: ['billing', 'transactions'] })
            break
          }
          case CheckoutEventNames.CHECKOUT_COMPLETED: {
            // Paddle's own success screen would otherwise sit on top of our
            // ActivationOverlay until the user clicks X — looks like the
            // checkout hung. Dismiss it so the activation stepper is visible.
            paddleRef.current?.Checkout.close()
            // Belt-and-suspenders: PAYMENT_INITIATED may drop on trial-signup
            // redirects. Don't reset the cooldown timestamp if it's already set.
            setOverlayVisible(true)
            setPaymentInitiatedAt((prev) => prev ?? Date.now())
            qc.invalidateQueries({ queryKey: ['billing', 'subscription'] })
            qc.invalidateQueries({ queryKey: ['billing', 'transactions'] })
            break
          }
          case CheckoutEventNames.CHECKOUT_PAYMENT_FAILED:
          case CheckoutEventNames.CHECKOUT_PAYMENT_ERROR:
          case CheckoutEventNames.CHECKOUT_ERROR: {
            setOverlayVisible(false)
            setPaymentInitiatedAt(null)
            setCooldownActive(false)
            toast.error('Payment did not go through. Please try again.')
            break
          }
          default:
            break
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
      if (cancelled) return
      if (instance) {
        paddleRef.current = instance
        setPaddle(instance)
      }
    })
    return () => {
      cancelled = true
      paddleRef.current = undefined
      setPaddle(undefined)
    }
  }, [config, resolved, qc])

  if (isLoading || !billing) {
    return <p className="text-muted-foreground">Loading billing info...</p>
  }

  const needsSubscription = !billing.active
  const checkoutReady = Boolean(paddle && config)

  async function handleUpdatePayment() {
    // No initialized Paddle.js yet — fall back to the hosted portal so the
    // action still works rather than silently no-opping.
    if (!paddle) {
      openPortal('update_payment')
      return
    }

    try {
      const { transaction_id } = await api.get<{ transaction_id: string }>(
        '/billing/payment-update-transaction',
      )
      paddle.Checkout.open({ transactionId: transaction_id })
    } catch {
      toast.error('Could not start the payment update. Please try again.')
    }
  }

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

      {!hideHeading && <CurrentPlanCard billing={billing} />}

      {needsSubscription && (
        <section className="relative space-y-4">
          <div className={overlayVisible ? 'pointer-events-none opacity-40' : ''}>
            {!hideHeading && (
              <>
                <h2 className="text-lg font-semibold text-foreground">Choose a Plan</h2>
                <p className="text-sm text-muted-foreground">Both plans include a 7-day free trial.</p>
              </>
            )}
            <CadenceToggle cadence={cadence} onChange={setCadence} />
            <ul className="grid items-stretch gap-4 sm:grid-cols-2">
              <PlanCard
                name="Starter"
                cadence={cadence}
                monthlyPrice={7}
                annualPrice={70}
                features={['5 vaults', 'Unlimited devices', '3 GB attachments', '500 AI queries/day']}
                tier="starter"
                paddle={paddle}
                config={config}
                disabled={!checkoutReady}
              />
              <PlanCard
                name="Pro"
                cadence={cadence}
                monthlyPrice={14}
                annualPrice={140}
                features={['15 vaults', 'Unlimited devices', '15 GB attachments', 'Unlimited AI', 'Smart retrieval (coming)']}
                tier="pro"
                paddle={paddle}
                config={config}
                disabled={!checkoutReady}
                recommended
              />
            </ul>
          </div>
          {(overlayVisible || activated) && (
            <ActivationOverlay
              state={
                activated
                  ? 'activated'
                  : cooldownActive
                    ? 'cooldown'
                    : 'accelerated'
              }
              subscriptionOk={activated}
              nextStep={qc.getQueryData<OnboardingStatus>(['onboarding', 'status'])?.next_step ?? 'billing'}
              transactionId={transactionId}
              onRefresh={() => window.location.reload()}
              onContactSupport={() => {
                const subject = encodeURIComponent('Activation taking too long')
                const body = encodeURIComponent(
                  `Hi — my payment went through but my account hasn't activated.\n\nReference: ${transactionId ?? 'n/a'}`,
                )
                window.location.href = `mailto:support@engram.page?subject=${subject}&body=${body}`
              }}
            />
          )}
        </section>
      )}

      {!hideHeading && billing.subscription && (
        <>
          <PendingChangeBanner scheduledChange={detail?.scheduled_change ?? null} />
          <PaymentMethodCard
            paymentMethod={history?.payment_method ?? null}
            onUpdate={handleUpdatePayment}
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

function CadenceToggle({
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

function PlanCard({
  name,
  cadence,
  monthlyPrice,
  annualPrice,
  features,
  tier,
  paddle,
  config,
  disabled,
  recommended = false,
}: {
  name: string
  cadence: BillingCadence
  monthlyPrice: number
  annualPrice: number
  features: string[]
  tier: 'starter' | 'pro'
  paddle: Paddle | undefined
  config: BillingConfig | undefined
  disabled: boolean
  recommended?: boolean
}) {
  const price =
    cadence === 'monthly' ? `$${monthlyPrice}/mo` : `$${annualPrice}/yr`
  const subPrice =
    cadence === 'annual'
      ? `$${(annualPrice / 12).toFixed(2)}/mo billed yearly`
      : `$${monthlyPrice * 12}/yr billed monthly`

  function handleCheckout() {
    if (!paddle || !config) return
    paddle.Checkout.open({
      items: [{ priceId: config.price_ids[tier][cadence], quantity: 1 }],
      customer: { email: config.customer_email },
      customData: config.custom_data,
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
      <p className="-mt-3 text-xs text-muted-foreground">{subPrice}</p>
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

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
  type OnboardingStatus,
} from '../api/queries'
import { api } from '../api/client'
import { useTheme } from '../theme/theme-provider'
import { Button } from '@/components/ui/button'
import { CadenceToggle, PLAN_CATALOG, PlanCard } from './plan-cards'
import CurrentPlanCard from './current-plan-card'
import PaymentMethodCard from './payment-method-card'
import BillingHistoryTable from './billing-history-table'
import PendingChangeBanner from './pending-change-banner'
import CancelPanel from './cancel-panel'
import PlanChangePanel from './plan-change-panel'
import { useSubscriptionActivatedEvents } from './use-subscription-activated-events'

// Time after CHECKOUT_COMPLETED we keep Paddle's own "Payment successful"
// screen visible while waiting for the backend subscription_activated push.
// Past this we close Paddle and surface a small recovery banner — the push
// listener stays connected, so a late broadcast still routes the user.
const COOLDOWN_MS = 15_000

const INLINE_FRAME_TARGET = 'paddle-checkout'

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
  // Onboarding mounts BillingPage with onActivated; settings does not. The
  // prop's presence is what flips Paddle from overlay → inline. Inline gives
  // the wizard step a continuous look (plan cards swap to Paddle's frame in
  // the same panel); overlay is the right shape for an on-demand settings
  // action where users expect a modal.
  const isInline = typeof onActivated === 'function'

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
  // call Checkout.close() on push activation or cooldown without re-init.
  const paddleRef = useRef<Paddle | undefined>(undefined)
  const [cadence, setCadence] = useState<BillingCadence>('monthly')

  // View states for the plan-picker section.
  //   idle      → plan cards visible
  //   checkout  → inline mode: Paddle frame mounted; overlay mode: modal open
  //   slow      → cooldown elapsed without a push event; show recovery banner
  const [checkingOut, setCheckingOut] = useState(false)
  const [completedAt, setCompletedAt] = useState<number | null>(null)
  const [slow, setSlow] = useState(false)
  const [transactionId, setTransactionId] = useState<string | null>(null)
  // Inline panel state for the in-app cancel + plan-change flows (replaces
  // the previous openPortal('cancel') / portal-redirect path).
  const [panel, setPanel] = useState<'cancel' | 'change' | null>(null)

  // Latch — onActivated must fire at most once even if the broadcast lands
  // multiple times (subscription.created followed by subscription.activated
  // on a trial→active flip).
  const onActivatedFiredRef = useRef(false)
  const onActivatedRef = useRef(onActivated)
  onActivatedRef.current = onActivated

  // Cooldown timer — starts on CHECKOUT_COMPLETED. If the activation push
  // doesn't land within COOLDOWN_MS, swap from Paddle's own success screen
  // to our recovery banner. The push listener stays connected.
  useEffect(() => {
    if (completedAt === null) return
    const t = setTimeout(() => {
      paddleRef.current?.Checkout.close()
      setSlow(true)
      setCheckingOut(false)
    }, COOLDOWN_MS)
    return () => clearTimeout(t)
  }, [completedAt])

  // Push handler — Paddle webhook flipped the subscription server-side and
  // the user channel just told us. Close Paddle, refresh local query state,
  // and (in onboarding mode) fetch the fresh onboarding/status to decide
  // where to route the user next.
  const handleSubscriptionActivated = useCallback(async () => {
    paddleRef.current?.Checkout.close()
    setCheckingOut(false)
    setCompletedAt(null)
    setSlow(false)
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
            // Belt-and-suspenders: either PAYMENT_INITIATED or COMPLETED may
            // drop on trial-signup redirects. Arm the cooldown timer on
            // whichever fires first (`?? Date.now()` guards against reset)
            // so a dropped COMPLETED still surfaces the recovery banner
            // instead of stranding the user on Paddle's inline frame.
            const txn = (event.data as { transaction_id?: string } | undefined)?.transaction_id ?? null
            setTransactionId(txn)
            setCompletedAt((prev) => prev ?? Date.now())
            qc.invalidateQueries({ queryKey: ['billing', 'subscription'] })
            qc.invalidateQueries({ queryKey: ['billing', 'transactions'] })
            break
          }
          case CheckoutEventNames.CHECKOUT_COMPLETED: {
            // Don't close Paddle — its built-in "Payment successful" screen
            // is the visible confirmation while we wait for the backend
            // webhook to fire the subscription_activated push. The cooldown
            // timer is the fallback if the push never arrives (and is also
            // armed here in case PAYMENT_INITIATED dropped).
            setCompletedAt((prev) => prev ?? Date.now())
            qc.invalidateQueries({ queryKey: ['billing', 'subscription'] })
            qc.invalidateQueries({ queryKey: ['billing', 'transactions'] })
            break
          }
          case CheckoutEventNames.CHECKOUT_PAYMENT_FAILED:
          case CheckoutEventNames.CHECKOUT_PAYMENT_ERROR:
          case CheckoutEventNames.CHECKOUT_ERROR: {
            setCheckingOut(false)
            setCompletedAt(null)
            setSlow(false)
            toast.error('Payment did not go through. Please try again.')
            break
          }
          default:
            break
        }
      },
      checkout: {
        settings: isInline
          ? {
              displayMode: 'inline',
              frameTarget: INLINE_FRAME_TARGET,
              frameInitialHeight: 450,
              frameStyle: 'width:100%; min-height:450px; background:transparent; border:none;',
              theme: resolved === 'dark' ? 'dark' : 'light',
              locale: 'en',
            }
          : {
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
  }, [config, resolved, qc, isInline])

  // Open checkout. In inline mode we set checkingOut first so the mount
  // div is in the DOM before Paddle tries to find it.
  const handleStartCheckout = useCallback(
    (tier: 'starter' | 'pro') => {
      if (!paddle || !config) return
      if (isInline) setCheckingOut(true)
      // Paddle finds the .paddle-checkout div by class — the div is rendered
      // synchronously by the same render cycle as the setCheckingOut update.
      // React 18 batches state into the same commit, so the DOM is ready by
      // the time Paddle queries it on the next microtask.
      queueMicrotask(() => {
        paddle.Checkout.open({
          items: [{ priceId: config.price_ids[tier][cadence], quantity: 1 }],
          customer: { email: config.customer_email },
          customData: config.custom_data,
        })
      })
    },
    [paddle, config, cadence, isInline],
  )

  if (isLoading || !billing) {
    return <p className="text-muted-foreground">Loading billing info...</p>
  }

  const needsSubscription = !billing.active
  const checkoutReady = Boolean(paddle && config)

  async function handleUpdatePayment() {
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

      {!hideHeading && (
        <CurrentPlanCard billing={billing}>
          {billing.subscription && panel === null && (
            <div className="flex flex-wrap justify-end gap-3">
              <Button onClick={() => setPanel('change')}>Change plan</Button>
              {/* Hide Cancel when (a) the subscription is already canceled,
                  OR (b) a scheduled cancel is in flight — Paddle keeps
                  status='active' until the effective date, so without the
                  scheduled_change check the button stays clickable and the
                  second click 5xx's ('subscription already scheduled to
                  cancel') with a vague 'Could not cancel' toast. */}
              {billing.subscription.status !== 'canceled' &&
                detail?.scheduled_change?.action !== 'cancel' && (
                  <Button variant="destructive" onClick={() => setPanel('cancel')}>
                    Cancel subscription
                  </Button>
                )}
            </div>
          )}
          {billing.subscription && panel === 'change' && (
            <PlanChangePanel billing={billing} onClose={() => setPanel(null)} />
          )}
          {billing.subscription && panel === 'cancel' && (
            <CancelPanel
              detail={
                detail ?? {
                  next_billed_at: billing.subscription.current_period_end,
                  amount: null,
                  currency: null,
                  billing_cycle: null,
                  scheduled_change: null,
                }
              }
              tier={billing.tier}
              onClose={() => setPanel(null)}
            />
          )}
        </CurrentPlanCard>
      )}

      {needsSubscription && (
        <section className="space-y-4">
          {slow ? (
            <SlowActivationBanner
              transactionId={transactionId}
              onRefresh={() => window.location.reload()}
            />
          ) : isInline && checkingOut ? (
            <>
              <button
                type="button"
                onClick={() => {
                  paddleRef.current?.Checkout.close()
                  setCheckingOut(false)
                  setCompletedAt(null)
                }}
                className="text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
              >
                ← Choose a different plan
              </button>
              <div className={INLINE_FRAME_TARGET} />
            </>
          ) : (
            <>
              {!hideHeading && (
                <>
                  <h2 className="text-lg font-semibold text-foreground">Choose a Plan</h2>
                  <p className="text-sm text-muted-foreground">Both plans include a 7-day free trial.</p>
                </>
              )}
              <CadenceToggle cadence={cadence} onChange={setCadence} />
              <ul className="grid items-stretch gap-4 sm:grid-cols-2">
                <PlanCard
                  name={PLAN_CATALOG.starter.name}
                  cadence={cadence}
                  monthlyPrice={PLAN_CATALOG.starter.monthlyPrice}
                  annualPrice={PLAN_CATALOG.starter.annualPrice}
                  features={PLAN_CATALOG.starter.features}
                  tier="starter"
                  onAction={handleStartCheckout}
                  disabled={!checkoutReady}
                />
                <PlanCard
                  name={PLAN_CATALOG.pro.name}
                  cadence={cadence}
                  monthlyPrice={PLAN_CATALOG.pro.monthlyPrice}
                  annualPrice={PLAN_CATALOG.pro.annualPrice}
                  features={PLAN_CATALOG.pro.features}
                  tier="pro"
                  onAction={handleStartCheckout}
                  disabled={!checkoutReady}
                  recommended
                />
              </ul>
            </>
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
          {/* Escape hatch: if the inline panels above fail (Paddle UI bug,
              network blip, an action we don't yet support inline) the user
              can still self-serve through Paddle's hosted portal. Sits
              outside the cards so it reads as a fallback option, not as
              one of the primary plan actions. */}
          <div className="flex justify-center pt-2">
            <button
              type="button"
              onClick={() => openPortal()}
              className="text-sm text-muted-foreground underline underline-offset-4 hover:text-foreground"
            >
              Manage payment in Paddle, our payment processor
            </button>
          </div>
        </>
      )}
    </article>
  )
}

function SlowActivationBanner({
  transactionId,
  onRefresh,
}: {
  transactionId: string | null
  onRefresh: () => void
}) {
  return (
    <div
      role="alert"
      className="rounded-lg border border-border bg-muted/50 p-4 text-sm"
    >
      <p className="font-medium text-foreground">
        Payment received. We're finishing your activation in the background.
      </p>
      <p className="mt-1 text-muted-foreground">
        This usually takes seconds. Refresh in a moment, or contact support if it persists.
      </p>
      <div className="mt-3 flex flex-wrap gap-2">
        <Button size="sm" onClick={onRefresh}>Refresh</Button>
        <Button
          size="sm"
          variant="outline"
          onClick={() => {
            const subject = encodeURIComponent('Activation taking too long')
            const body = encodeURIComponent(
              `Hi — my payment went through but my account hasn't activated.\n\nReference: ${transactionId ?? 'n/a'}`,
            )
            window.location.href = `mailto:support@engram.page?subject=${subject}&body=${body}`
          }}
        >
          Contact support
        </Button>
      </div>
      {transactionId ? (
        <p className="mt-3 text-xs text-muted-foreground">Reference: {transactionId}</p>
      ) : null}
    </div>
  )
}


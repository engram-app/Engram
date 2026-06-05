import { useCallback, useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { api } from '../api/client'
import type { OnboardingStatus } from '../api/queries'

export type WatcherState = 'idle' | 'background' | 'accelerated' | 'cooldown' | 'activated'

const BACKGROUND_MS = 10_000
const ACCELERATED_MS = 1_000
const COOLDOWN_MS = 5_000
const ACCELERATED_BUDGET_MS = 15_000

interface Options {
  onActivated: (status: OnboardingStatus) => void
  enabled: boolean
}

interface WatcherApi {
  state: WatcherState
  subscriptionOk: boolean
  onCheckoutOpened: () => void
  onPaymentInitiated: () => void
  onPaymentFailed: () => void
}

function cadenceFor(state: WatcherState): number | null {
  switch (state) {
    case 'idle': return null
    case 'background': return BACKGROUND_MS
    case 'accelerated': return ACCELERATED_MS
    case 'cooldown': return COOLDOWN_MS
    case 'activated': return null
  }
}

export function useActivationWatcher({ onActivated, enabled }: Options): WatcherApi {
  const [state, setState] = useState<WatcherState>('idle')
  const [subscriptionOk, setSubscriptionOk] = useState(false)
  const qc = useQueryClient()

  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const activatedRef = useRef(false)
  const acceleratedStartRef = useRef<number | null>(null)
  const stateRef = useRef<WatcherState>('idle')
  const onActivatedRef = useRef(onActivated)
  const subscriptionOkRef = useRef(false)
  const mountedRef = useRef(true)

  stateRef.current = state
  onActivatedRef.current = onActivated
  subscriptionOkRef.current = subscriptionOk

  const scheduleRef = useRef<() => void>(() => {})

  const tick = useCallback(async () => {
    try {
      const status = await api.get<OnboardingStatus>('/onboarding/status')
      if (!mountedRef.current) return
      qc.setQueryData(['onboarding', 'status'], status)
      // Always refresh the live billing surface so settings-mode users see
      // CurrentPlanCard / plan-gate update the moment the webhook lands.
      qc.invalidateQueries({ queryKey: ['billing', 'status'] })
      if (status.subscription_ok && !subscriptionOkRef.current) {
        subscriptionOkRef.current = true
        setSubscriptionOk(true)
      }
      if (status.next_step !== 'billing' && !activatedRef.current) {
        activatedRef.current = true
        setState('activated')
        onActivatedRef.current(status)
        return
      }
    } catch (err) {
      // Transient errors must NOT stop the chain — the bug we're fixing IS a
      // stuck watcher. Log and reschedule.
      console.error('activation poll failed; retrying', err)
    }

    if (!mountedRef.current) return
    if (activatedRef.current) return

    if (
      stateRef.current === 'accelerated' &&
      acceleratedStartRef.current !== null &&
      Date.now() - acceleratedStartRef.current >= ACCELERATED_BUDGET_MS
    ) {
      setState('cooldown')
      stateRef.current = 'cooldown'
    }

    scheduleRef.current()
  }, [qc])

  const schedule = useCallback(() => {
    clearTimeout(timer.current)
    if (!mountedRef.current) return
    if (activatedRef.current) return
    const cadence = cadenceFor(stateRef.current)
    if (cadence === null) return
    timer.current = setTimeout(() => { void tick() }, cadence)
  }, [tick])

  scheduleRef.current = schedule

  // Mount-time cache check: if the user lands on the billing step with a
  // cached onboarding status already past 'billing' (paid in another tab,
  // browser-back, refresh), fire onActivated synchronously instead of
  // waiting for the first background poll (10s).
  //
  // Only relevant in onboarding mode (onActivated is a real function), not
  // settings mode where there is no "past billing" navigation.
  useEffect(() => {
    if (typeof onActivated !== 'function') return
    const cached = qc.getQueryData<OnboardingStatus>(['onboarding', 'status'])
    if (cached && cached.next_step !== 'billing' && !activatedRef.current) {
      activatedRef.current = true
      setState('activated')
      onActivatedRef.current(cached)
    }
    // Intentionally mount-only — qc is stable, onActivated identity is
    // captured via ref.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  useEffect(() => {
    mountedRef.current = true
    if (!enabled) return
    schedule()
    return () => {
      mountedRef.current = false
      clearTimeout(timer.current)
    }
  }, [enabled, state, schedule])

  const onCheckoutOpened = useCallback(() => {
    if (activatedRef.current) return
    setState((prev) => (prev === 'idle' ? 'background' : prev))
  }, [])

  const onPaymentInitiated = useCallback(() => {
    if (activatedRef.current) return
    // Idempotent: if PAYMENT_INITIATED already accelerated us, a follow-up
    // CHECKOUT_COMPLETED must NOT reset the 15s budget. Keep the original
    // t=0 timestamp.
    if (acceleratedStartRef.current !== null) return
    acceleratedStartRef.current = Date.now()
    // Transition from any non-activated state (idle, background, cooldown)
    // into accelerated. This keeps PAYMENT_INITIATED a credible "user is
    // checking out" signal even if CHECKOUT_LOADED dropped.
    setState('accelerated')
  }, [])

  const onPaymentFailed = useCallback(() => {
    if (activatedRef.current) return
    acceleratedStartRef.current = null
    // Reset to idle (not background) — a failed payment should NOT keep us
    // polling forever. The next CHECKOUT_LOADED or PAYMENT_INITIATED will
    // re-arm the watcher.
    setState('idle')
  }, [])

  return { state, subscriptionOk, onCheckoutOpened, onPaymentInitiated, onPaymentFailed }
}

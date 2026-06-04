import { useCallback, useEffect, useRef, useState } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { api } from '../api/client'
import type { OnboardingStatus } from '../api/queries'

export type WatcherState = 'background' | 'accelerated' | 'cooldown' | 'activated'

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
  paymentInitiatedAt: number | null
  subscriptionOkAt: number | null
  onPaymentInitiated: () => void
  onPaymentFailed: () => void
}

function cadenceFor(state: WatcherState): number | null {
  switch (state) {
    case 'background': return BACKGROUND_MS
    case 'accelerated': return ACCELERATED_MS
    case 'cooldown': return COOLDOWN_MS
    case 'activated': return null
  }
}

export function useActivationWatcher({ onActivated, enabled }: Options): WatcherApi {
  const [state, setState] = useState<WatcherState>('background')
  const [paymentInitiatedAt, setPaymentInitiatedAt] = useState<number | null>(null)
  const [subscriptionOkAt, setSubscriptionOkAt] = useState<number | null>(null)
  const qc = useQueryClient()

  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const activatedRef = useRef(false)
  const acceleratedStartRef = useRef<number | null>(null)
  const stateRef = useRef<WatcherState>('background')
  const onActivatedRef = useRef(onActivated)
  const subscriptionOkAtRef = useRef<number | null>(null)

  stateRef.current = state
  onActivatedRef.current = onActivated

  const scheduleRef = useRef<() => void>(() => {})

  const tick = useCallback(async () => {
    try {
      const status = await api.get<OnboardingStatus>('/onboarding/status')
      qc.setQueryData(['onboarding', 'status'], status)
      if (status.subscription_ok && subscriptionOkAtRef.current === null) {
        subscriptionOkAtRef.current = Date.now()
        setSubscriptionOkAt(subscriptionOkAtRef.current)
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
    if (activatedRef.current) return
    const cadence = cadenceFor(stateRef.current)
    if (cadence === null) return
    timer.current = setTimeout(() => { void tick() }, cadence)
  }, [tick])

  scheduleRef.current = schedule

  useEffect(() => {
    if (!enabled) return
    schedule()
    return () => clearTimeout(timer.current)
  }, [enabled, state, schedule])

  const onPaymentInitiated = useCallback(() => {
    if (activatedRef.current) return
    setPaymentInitiatedAt(Date.now())
    acceleratedStartRef.current = Date.now()
    setState('accelerated')
  }, [])

  const onPaymentFailed = useCallback(() => {
    if (activatedRef.current) return
    acceleratedStartRef.current = null
    setState('background')
  }, [])

  return { state, paymentInitiatedAt, subscriptionOkAt, onPaymentInitiated, onPaymentFailed }
}

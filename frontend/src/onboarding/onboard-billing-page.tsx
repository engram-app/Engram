import { useCallback, useState } from 'react'
import { Navigate, useNavigate } from 'react-router'
import { useQueryClient } from '@tanstack/react-query'
import { toast } from 'sonner'
import { api } from '../api/client'
import { useOnboardingStatus, type OnboardingStatus } from '../api/queries'
import BillingPage from '../billing/billing-page'

function nextPath(status: OnboardingStatus): string {
  return status.next_step === 'done' ? '/' : `/onboard/${status.next_step}`
}

export default function OnboardBillingPage() {
  const navigate = useNavigate()
  const qc = useQueryClient()
  const { data: onboarding } = useOnboardingStatus()
  const [freeLoading, setFreeLoading] = useState(false)

  const onActivated = useCallback(
    (status: OnboardingStatus) => {
      navigate(nextPath(status), { replace: true })
    },
    [navigate],
  )

  const handleContinueFree = useCallback(async () => {
    setFreeLoading(true)
    try {
      const status = await api.post<OnboardingStatus>('/onboarding/accept_free_tier')
      qc.setQueryData(['onboarding', 'status'], status)
      const next = status.next_step === 'done' ? '/' : `/onboard/${status.next_step}`
      navigate(next, { replace: true })
    } catch {
      toast.error('Could not continue. Please try again.')
    } finally {
      setFreeLoading(false)
    }
  }, [navigate, qc])

  // Cached/fetched status already past billing (e.g. user advanced in another
  // tab, or returned to /onboard/billing after subscribing) — bounce forward
  // to their actual next step instead of re-showing the plan picker. Keys off
  // `next_step`, not `steps` (billing stays in `steps` even once satisfied).
  if (onboarding && onboarding.next_step !== 'billing') {
    return <Navigate to={nextPath(onboarding)} replace />
  }

  return (
    <section className="m-auto max-h-full w-full max-w-2xl overflow-y-auto px-4 pb-[14vh] pt-8">
      <div className="rounded-2xl border border-border bg-background p-6 sm:p-8">
        <header className="mb-8 text-center">
          <h1 className="text-4xl font-extrabold tracking-tight text-foreground">Choose Your Plan</h1>
          <p className="mx-auto mt-3 max-w-md text-balance text-muted-foreground">
            Start with a 7-day free trial — a card is required, but you won't be charged until it ends.
          </p>
        </header>
        <BillingPage hideHeading onActivated={onActivated} />
        <section className="mt-12 border-t border-border pt-8 text-center">
          <button
            type="button"
            onClick={handleContinueFree}
            disabled={freeLoading}
            className="text-sm font-medium text-muted-foreground underline underline-offset-4 hover:text-foreground disabled:opacity-50"
          >
            Continue with Free →
          </button>
          <p className="mt-2 text-xs text-muted-foreground">
            10k notes · 1 vault · markdown only · upgrade anytime
          </p>
        </section>
      </div>
    </section>
  )
}

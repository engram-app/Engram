import { useCallback } from 'react'
import { useNavigate } from 'react-router'
import type { OnboardingStatus } from '../api/queries'
import BillingPage from '../billing/billing-page'

export default function OnboardBillingPage() {
  const navigate = useNavigate()

  const onActivated = useCallback(
    (status: OnboardingStatus) => {
      const next = status.next_step === 'done' ? '/' : `/onboard/${status.next_step}`
      navigate(next, { replace: true })
    },
    [navigate],
  )

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
      </div>
    </section>
  )
}

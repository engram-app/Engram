import { useEffect } from 'react'
import { useNavigate } from 'react-router'
import { useOnboardingStatus } from '../api/queries'
import BillingPage from '../billing/billing-page'

export default function OnboardBillingPage() {
  const navigate = useNavigate()
  const { data } = useOnboardingStatus()

  useEffect(() => {
    if (data?.next_step === 'done') {
      navigate('/', { replace: true })
    }
  }, [data?.next_step, navigate])

  return (
    <section className="m-auto max-h-full w-full max-w-2xl overflow-y-auto px-4 pb-[14vh] pt-8">
      <header className="mb-8 text-center">
        <h1 className="text-4xl font-extrabold tracking-tight text-foreground">Choose Your Plan</h1>
        <p className="mx-auto mt-3 max-w-md text-balance text-muted-foreground">
          Start with a 7-day free trial — a card is required, but you won't be charged until it ends.
        </p>
      </header>
      <BillingPage hideHeading />
    </section>
  )
}

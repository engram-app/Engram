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
    <section className="onboard-billing">
      <p>Pick a plan to start your 7-day free trial.</p>
      <BillingPage />
    </section>
  )
}

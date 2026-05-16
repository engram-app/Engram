import { Navigate, Outlet } from 'react-router'
import { useOnboardingStatus } from '../api/queries'

export default function OnboardingGate() {
  const { data, isLoading } = useOnboardingStatus()

  if (isLoading || !data) {
    return <p>Loading...</p>
  }

  if (!data.enabled || data.next_step === 'done') {
    return <Outlet />
  }

  return <Navigate to={`/onboard/${data.next_step}`} replace />
}

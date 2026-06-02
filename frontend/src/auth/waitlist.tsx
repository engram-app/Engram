import { lazy, Suspense } from 'react'
import { Navigate } from 'react-router'
import { config } from '../config'
import { ROUTES } from '../routes'
import AuthLayout from './auth-layout'

const isClerk = config.authProvider === 'clerk'

const ClerkWaitlistPage = isClerk
  ? lazy(() =>
      import('@clerk/react').then((mod) => ({
        default: () => (
          <AuthLayout>
            <mod.Waitlist signInUrl={ROUTES.SIGN_IN} />
          </AuthLayout>
        ),
      })),
    )
  : null

export default function WaitlistPage() {
  if (!ClerkWaitlistPage || !config.clerkWaitlistMode) {
    return <Navigate to={ROUTES.SIGN_UP} replace />
  }

  return (
    <Suspense fallback={<p>Loading...</p>}>
      <ClerkWaitlistPage />
    </Suspense>
  )
}

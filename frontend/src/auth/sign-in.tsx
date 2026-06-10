import { lazy, Suspense } from 'react'
import { useSearchParams } from 'react-router'
import { useConfig } from '../config-context'
import AuthLayout from './auth-layout'
import SignupRejectionNotice from './signup-rejection-notice'
import { safeReturnTo } from './safe-return-to'

// Both lazy refs are declared at module scope so React preserves the lazy
// component identity across renders. Only one is actually rendered per
// run — the auth provider is resolved at config load and never changes.
const ClerkSignIn = lazy(() => import('./clerk-sign-in'))
const LocalSignIn = lazy(() => import('./local-sign-in'))

export default function SignInPage() {
  const [searchParams] = useSearchParams()
  const returnTo = safeReturnTo(searchParams.get('return_to'))
  const config = useConfig()

  if (config.authProvider === 'clerk') {
    return (
      <AuthLayout>
        <div className="flex w-full flex-col items-center">
          <SignupRejectionNotice />
          <Suspense fallback={<p>Loading...</p>}>
            <ClerkSignIn returnTo={returnTo} />
          </Suspense>
        </div>
      </AuthLayout>
    )
  }

  return (
    <Suspense fallback={<p>Loading...</p>}>
      <LocalSignIn />
    </Suspense>
  )
}

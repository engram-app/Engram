import { lazy, Suspense } from 'react'
import { useSearchParams } from 'react-router'
import { config } from '../config'
import AuthLayout from './auth-layout'
import SignupRejectionNotice from './signup-rejection-notice'
import { safeReturnTo } from './safe-return-to'

const isClerk = config.authProvider === 'clerk'

const ClerkSignIn = isClerk
  ? lazy(() =>
      import('@clerk/clerk-react').then((mod) => ({
        default: ({ returnTo }: { returnTo: string }) => (
          <mod.SignIn routing="hash" forceRedirectUrl={returnTo} />
        ),
      })),
    )
  : null

const LocalSignIn = lazy(() => import('./local-sign-in'))

export default function SignInPage() {
  const [searchParams] = useSearchParams()
  const returnTo = safeReturnTo(searchParams.get('return_to'))

  if (ClerkSignIn) {
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

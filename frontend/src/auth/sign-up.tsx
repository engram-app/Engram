import { lazy, Suspense } from 'react'
import { config } from '../config'
import AuthLayout from './auth-layout'

const isClerk = config.authProvider === 'clerk'

const ClerkSignUpPage = isClerk
  ? lazy(() =>
      import('@clerk/react').then((mod) => ({
        default: () => (
          <AuthLayout>
            <mod.SignUp routing="hash" forceRedirectUrl="/" />
          </AuthLayout>
        ),
      }))
    )
  : null

const LocalSignUp = lazy(() => import('./local-sign-up'))

export default function SignUpPage() {
  return (
    <Suspense fallback={<p>Loading...</p>}>
      {ClerkSignUpPage ? <ClerkSignUpPage /> : <LocalSignUp />}
    </Suspense>
  )
}

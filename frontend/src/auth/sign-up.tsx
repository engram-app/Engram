import { lazy, Suspense } from 'react'
import { useConfig } from '../config-context'
import AuthLayout from './auth-layout'

const ClerkSignUpPage = lazy(() =>
  import('@clerk/react').then((mod) => ({
    default: () => (
      <AuthLayout>
        <mod.SignUp routing="hash" forceRedirectUrl="/" />
      </AuthLayout>
    ),
  })),
)

const LocalSignUp = lazy(() => import('./local-sign-up'))

export default function SignUpPage() {
  const config = useConfig()
  const isClerk = config.authProvider === 'clerk'
  return (
    <Suspense fallback={<p>Loading...</p>}>
      {isClerk ? <ClerkSignUpPage /> : <LocalSignUp />}
    </Suspense>
  )
}

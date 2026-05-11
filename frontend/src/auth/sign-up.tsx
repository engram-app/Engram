import { lazy, Suspense } from 'react'
import { config } from '../config'

const isClerk = config.authProvider === 'clerk'

const ClerkSignUpPage = isClerk
  ? lazy(() =>
      import('@clerk/clerk-react').then((mod) => ({
        default: () => (
          <main style={{ display: 'flex', justifyContent: 'center', paddingTop: '4rem' }}>
            <mod.SignUp routing="hash" forceRedirectUrl="/" />
          </main>
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

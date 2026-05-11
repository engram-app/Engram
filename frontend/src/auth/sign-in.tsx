import { lazy, Suspense } from 'react'
import { useSearchParams } from 'react-router'
import { config } from '../config'
import { safeReturnTo } from './safe-return-to'

const isClerk = config.authProvider === 'clerk'

const ClerkSignInPage = isClerk
  ? lazy(() =>
      import('@clerk/clerk-react').then((mod) => ({
        default: ({ returnTo }: { returnTo: string }) => (
          <main style={{ display: 'flex', justifyContent: 'center', paddingTop: '4rem' }}>
            <mod.SignIn routing="hash" forceRedirectUrl={returnTo} />
          </main>
        ),
      })),
    )
  : null

const LocalSignIn = lazy(() => import('./local-sign-in'))

export default function SignInPage() {
  const [searchParams] = useSearchParams()
  const returnTo = safeReturnTo(searchParams.get('return_to'))

  return (
    <Suspense fallback={<p>Loading...</p>}>
      {ClerkSignInPage ? <ClerkSignInPage returnTo={returnTo} /> : <LocalSignIn />}
    </Suspense>
  )
}

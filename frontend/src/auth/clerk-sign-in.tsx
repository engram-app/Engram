import { SignIn } from '@clerk/react'
// Legacy hook returns `{ isLoaded, signIn }` with `signIn.firstFactorVerification`.
// The root `@clerk/react` `useSignIn` now returns the signal-based shape, which
// doesn't expose that field — we only need to read post-OAuth verification errors.
import { useSignIn } from '@clerk/react/legacy'
import { useEffect } from 'react'
import { useNavigate } from 'react-router'
import { ROUTES } from '../routes'

// Clerk's <SignIn /> has no built-in UI for the OAuth-then-waitlist-blocked
// state: when Google verifies the identity but Clerk's restriction kills the
// implicit sign-up (`signIn.firstFactorVerification.error.code ===
// 'sign_up_restricted_waitlist'`), the component just spins. ClerkProvider's
// `waitlistUrl` only governs the "Sign up" CTA, not OAuth recovery. Detect
// the error reactively via useSignIn() and route to /waitlist ourselves.
export default function ClerkSignIn({ returnTo }: { returnTo: string }) {
  const { signIn, isLoaded } = useSignIn()
  const navigate = useNavigate()
  const restricted =
    signIn?.firstFactorVerification?.error?.code === 'sign_up_restricted_waitlist'

  useEffect(() => {
    if (isLoaded && restricted) navigate(ROUTES.WAITLIST, { replace: true })
  }, [isLoaded, restricted, navigate])

  return <SignIn routing="hash" forceRedirectUrl={returnTo} />
}

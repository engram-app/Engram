import { SignIn } from "@clerk/react";

// No waitlist-recovery handling here any more. This component used to watch
// `signIn.firstFactorVerification.error.code === 'sign_up_restricted_waitlist'`
// and redirect to /waitlist, because Clerk's <SignIn /> just spins when Google
// verifies an identity but a Dashboard restriction kills the implicit sign-up.
//
// That state is unreachable with sign-up open: Clerk only emits the code while
// Dashboard → Restrictions → Waitlist is on. If that mode is ever re-enabled,
// this recovery has to come back with it — see the removal PR for the full
// dashboard/env/code ordering.
export default function ClerkSignIn({ returnTo }: { returnTo: string }) {
	return <SignIn routing="hash" forceRedirectUrl={returnTo} />;
}

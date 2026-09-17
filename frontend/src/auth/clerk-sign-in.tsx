import { SignIn } from "@clerk/react";
import { ROUTES } from "../routes";
import { authUrlWithReturnTo } from "./sign-in-redirect";

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
	return (
		<SignIn
			routing="hash"
			forceRedirectUrl={returnTo}
			// Overrides the BARE `signUpUrl` on ClerkProvider. That one is a
			// plain href, so following it dropped `return_to` before /sign-up
			// could read it — the half of the MCP-first dead end that no amount
			// of fixing /sign-up alone would have closed.
			signUpUrl={authUrlWithReturnTo(ROUTES.SIGN_UP, returnTo)}
		/>
	);
}

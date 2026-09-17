import { SignUp } from "@clerk/react";
import { ROUTES } from "../routes";
import { authUrlWithReturnTo } from "./sign-in-redirect";

// Mirrors clerk-sign-in.tsx. `forceRedirectUrl` was hardcoded to "/" here,
// which is how an MCP-first signup lost its authorization: a user with no
// account reaches /oauth/consent, AuthGuard bounces them to /sign-in with the
// request in `return_to`, they click "Sign up" — and landed on the dashboard
// with the waiting client never mentioned again. Nothing was parked, because
// the consent page (which does the parking) never rendered.
export default function ClerkSignUp({ returnTo }: { returnTo: string }) {
	return (
		<SignUp
			routing="hash"
			forceRedirectUrl={returnTo}
			signInUrl={authUrlWithReturnTo(ROUTES.SIGN_IN, returnTo)}
		/>
	);
}

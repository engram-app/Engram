import { ROUTES } from "../routes";

// Build the sign-in URL for a signed-out user, preserving where they were
// headed as an encoded `return_to` so the post-login redirect lands them
// back. Home gets no round-trip — that's already the default landing.
//
// Shared by AuthGuard (protected routes) and CatchAllRoute (unknown paths)
// so the two redirect surfaces can't drift apart.
export function signInRedirectTarget(location: {
	pathname: string;
	search: string;
	hash: string;
}): string {
	const returnTo = location.pathname + location.search + location.hash;
	return returnTo && returnTo !== ROUTES.HOME
		? `${ROUTES.SIGN_IN}?return_to=${encodeURIComponent(returnTo)}`
		: ROUTES.SIGN_IN;
}

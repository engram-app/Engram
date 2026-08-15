import { ROUTES } from "../routes";

// Build the sign-in URL for a signed-out user, preserving where they were
// headed as an encoded `return_to` so the post-login redirect lands them
// back. Home gets no round-trip — that's already the default landing.
//
// Shared by AuthGuard (protected routes) and CatchAllRoute (unknown paths)
// so the two redirect surfaces can't drift apart.
/** Query params that are credentials, not navigation state.
 *
 *  `return_to` is round-tripped through the sign-in page and handed to Clerk
 *  as `forceRedirectUrl`, so anything in it survives in the address bar and in
 *  browser history for the whole login journey — and rides along to a third
 *  party. `/link?code=` (RFC 8628 device code) and `/reset-password?token=`
 *  are both single-use credentials that arrive by URL, so both would otherwise
 *  make that trip. Strip them: the destination is worth preserving, the
 *  credential is not, and a user who lands back on `/link` without a prefilled
 *  code simply types it, which is the flow that existed before. */
const CREDENTIAL_PARAMS = ["code", "token"];

export function signInRedirectTarget(location: {
	pathname: string;
	search: string;
	hash: string;
}): string {
	const params = new URLSearchParams(location.search);
	for (const key of CREDENTIAL_PARAMS) {
		params.delete(key);
	}
	const search = params.toString();
	const returnTo = location.pathname + (search ? `?${search}` : "") + location.hash;
	return returnTo && returnTo !== ROUTES.HOME
		? `${ROUTES.SIGN_IN}?return_to=${encodeURIComponent(returnTo)}`
		: ROUTES.SIGN_IN;
}

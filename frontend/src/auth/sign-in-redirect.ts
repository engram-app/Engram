import { ROUTES } from "../routes";
import { CREDENTIAL_PARAMS, stashCredentialsFrom } from "./credential-handoff";

// Build the sign-in URL for a signed-out user, preserving where they were
// headed as an encoded `return_to` so the post-login redirect lands them
// back. Home gets no round-trip — that's already the default landing.
//
// Shared by AuthGuard (protected routes) and CatchAllRoute (unknown paths)
// so the two redirect surfaces can't drift apart.
/** Where to send a signed-out user, with credentials taken out of the URL.
 *
 *  `return_to` is round-tripped through the sign-in page and handed to Clerk as
 *  `forceRedirectUrl`, so anything in it sits in the address bar and in history
 *  for the whole login journey, and goes to a third party on the way. The
 *  device code (`/link?code=`) and the password-reset token both arrive that
 *  way, so both are stripped — and stashed first, per credential-handoff, so
 *  the destination page still gets them. */
export function signInRedirectTarget(location: {
	pathname: string;
	search: string;
	hash: string;
}): string {
	// Hand the credential to sessionStorage BEFORE stripping it, so the
	// destination page can still use it. Done here rather than at the two call
	// sites because this function is the single seam every sign-in redirect
	// passes through — a third caller would otherwise silently drop the code.
	stashCredentialsFrom(location.search, location.pathname);

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

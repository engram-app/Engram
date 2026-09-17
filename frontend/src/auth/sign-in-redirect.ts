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
	return authUrlWithReturnTo(ROUTES.SIGN_IN, returnTo);
}

/** Attach `return_to` to an auth route, or leave it bare when the destination
 *  is home (already the default landing, so the round-trip buys nothing).
 *
 *  Also used for the cross-links BETWEEN the two auth pages. Clerk renders
 *  those as plain hrefs from `signUpUrl`/`signInUrl`, and a bare one silently
 *  drops the destination: a user who arrived at `/sign-in` mid-OAuth and then
 *  clicked "Sign up" lost the whole authorization request before the consent
 *  page ever rendered, so there was nothing parked for the wizard to resume.
 *
 *  `returnTo` MUST already be stripped and sanitized — pass the output of
 *  `safeReturnTo`, or a value this module built. Unlike `signInRedirectTarget`
 *  this does NOT stash-and-strip `CREDENTIAL_PARAMS`, so handing it a raw
 *  `location.search` would put a device code or reset token into an href and
 *  then into Clerk's hands. Every current caller reads through `safeReturnTo`
 *  first; a new one that skips it is the way that guarantee gets lost. */
export function authUrlWithReturnTo(route: string, returnTo: string): string {
	return returnTo && returnTo !== ROUTES.HOME
		? `${route}?return_to=${encodeURIComponent(returnTo)}`
		: route;
}

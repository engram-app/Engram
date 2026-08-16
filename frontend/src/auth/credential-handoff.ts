/**
 * Carry a URL-borne credential across a sign-in redirect without putting it in
 * the URL.
 *
 * Two credentials arrive as query params: the RFC 8628 device code on `/link`
 * (the plugin opens `verification_uri_complete`) and the password-reset token.
 * Both used to ride `return_to` through the sign-in page and on to Clerk as
 * `forceRedirectUrl`, so they sat in the address bar, in history, and in the
 * Referer of every same-origin request for the whole login journey.
 *
 * Stripping them from `return_to` fixed that and broke the flow: a signed-out
 * user arriving from the plugin — the COMMON case, since they have never signed
 * in to that browser — landed back on a bare `/link` with nothing prefilled,
 * which is the retyping the complete URL exists to avoid.
 *
 * sessionStorage is the handoff. It is per-tab, dies with the tab, is not sent
 * with any request, and never enters history — so the credential survives the
 * redirect it has to survive, and nothing else. `take` deletes on read.
 *
 * Read-once is not the same as short-lived, and the reset token is the
 * exception: ResetPasswordPage puts it BACK after reading, because a user who
 * mistypes and reloads twice would otherwise be stranded with no way forward
 * but re-opening the email. So an ABANDONED reset leaves its token in
 * sessionStorage for the life of the tab. That is a deliberate trade against
 * the address bar, which is worse in every way — history, Referer, and every
 * Sentry event — but it means "cannot linger" holds for the device code and
 * not for the token. The token is cleared the moment the reset succeeds.
 *
 * Each stash is STAMPED with the path it was captured on, and `take` returns
 * nothing on a mismatch. Without that, a stash outlives its flow: abandon
 * sign-in from `/link?code=A`, reach `/link` later in the same tab from the
 * onboarding wizard, and the dead code is consumed, prefilled, and
 * auto-verified into "This code is invalid or has expired." It also keeps a
 * generic `code` param — OAuth callbacks, promo links — from being handed to
 * the device-link page, which is the only reader of `code`.
 */

const PREFIX = "engram:handoff:";

/** Paths compare after normalization, because the two sides read it from
 *  different places: the stash side takes `location.pathname` verbatim, while
 *  the consuming page names its own route (`ROUTES.DEVICE_LINK`). React-router
 *  matches `/link/` and `/Link` to `path="/link"` but leaves `pathname` as
 *  written, so an arrival at `/link/?code=…` stashed under `/link/`, failed to
 *  match `/link`, and the code was dropped — silently, and unrecoverably,
 *  since a rejected stash is also removed. */
function normalizePath(pathname: string): string {
	const lower = pathname.toLowerCase();
	return lower.length > 1 && lower.endsWith("/") ? lower.slice(0, -1) : lower;
}

/** Query params that are credentials rather than navigation state. */
export const CREDENTIAL_PARAMS = ["code", "token"] as const;

export function stashCredential(name: string, value: string, pathname: string): void {
	if (typeof window === "undefined" || !value) {
		return;
	}
	try {
		window.sessionStorage.setItem(
			PREFIX + name,
			JSON.stringify({ value, pathname: normalizePath(pathname) }),
		);
	} catch {
		// Storage disabled or full. The user retypes the code; losing the flow
		// entirely would be worse than the inconvenience.
	}
}

/** Read and remove. Returns "" when absent, or when the credential was
 *  captured on a different path than `pathname`. Removes either way — a stash
 *  the wrong page just rejected has no other consumer, and leaving it would let
 *  it surface again on the next navigation. */
export function takeCredential(name: string, pathname: string): string {
	if (typeof window === "undefined") {
		return "";
	}
	try {
		const raw = window.sessionStorage.getItem(PREFIX + name);
		window.sessionStorage.removeItem(PREFIX + name);
		if (!raw) {
			return "";
		}
		// A plain string is a stash written by the previous build, still in a
		// tab that was open across the deploy. Unstamped means unverifiable,
		// so drop it: the user retypes, which is what they did before any of
		// this existed.
		const parsed = JSON.parse(raw) as { value?: string; pathname?: string };
		return parsed?.pathname === normalizePath(pathname) ? (parsed.value ?? "") : "";
	} catch {
		return "";
	}
}

/** Stash every credential param present in `search`, before it is stripped,
 *  stamped with the path it arrived on. */
export function stashCredentialsFrom(search: string, pathname: string): void {
	const params = new URLSearchParams(search);
	for (const name of CREDENTIAL_PARAMS) {
		const value = params.get(name);
		if (value) {
			stashCredential(name, value, pathname);
		}
	}
}

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
 * redirect it has to survive, and nothing else. Read-once: `take` deletes on
 * read, so a code cannot linger after the flow it belongs to.
 */

const PREFIX = "engram:handoff:";

/** Query params that are credentials rather than navigation state. */
export const CREDENTIAL_PARAMS = ["code", "token"] as const;

export function stashCredential(name: string, value: string): void {
	if (typeof window === "undefined" || !value) {
		return;
	}
	try {
		window.sessionStorage.setItem(PREFIX + name, value);
	} catch {
		// Storage disabled or full. The user retypes the code; losing the flow
		// entirely would be worse than the inconvenience.
	}
}

/** Read and remove. Returns "" when absent. */
export function takeCredential(name: string): string {
	if (typeof window === "undefined") {
		return "";
	}
	try {
		const value = window.sessionStorage.getItem(PREFIX + name) ?? "";
		window.sessionStorage.removeItem(PREFIX + name);
		return value;
	} catch {
		return "";
	}
}

/** Stash every credential param present in `search`, before it is stripped. */
export function stashCredentialsFrom(search: string): void {
	const params = new URLSearchParams(search);
	for (const name of CREDENTIAL_PARAMS) {
		const value = params.get(name);
		if (value) {
			stashCredential(name, value);
		}
	}
}

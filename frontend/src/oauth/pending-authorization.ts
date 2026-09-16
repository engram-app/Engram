/**
 * Remembers an in-flight OAuth authorization across the onboarding detour.
 *
 * A user can reach `/oauth/consent` having just signed up inside the OAuth
 * flow itself, with no terms accepted, no plan, and no vault. Approving in that
 * state mints a grant the gate then refuses on every call, so the consent page
 * sends them through the wizard first. This is how it gets them back.
 *
 * sessionStorage rather than a `?n=` param, for the same reason
 * `credential-handoff.ts` uses it: the wizard is four screens with their own
 * navigations, and threading a query param through every one of them means
 * touching every step page and losing the request the first time somebody
 * forgets. It is per-tab, dies with the tab, and never enters history or a
 * Referer. Same mechanism, different contents — that module is explicitly
 * about CREDENTIALS stripped from URLs, and this is navigation state, so it
 * does not belong in it.
 *
 * Reading does NOT consume. Several places ask where a finished wizard should
 * land, and the first to ask must not delete the answer for the rest.
 */

import { ROUTES } from "../routes";

const KEY = "engram:pending-oauth";

export interface PendingAuthorization {
	/** The full consent URL, query string included, so `state` and the PKCE
	 *  challenge survive the detour and the original request is honored. */
	returnTo: string;
	/** Catalog slug of the client being authorized, or null when it cannot be
	 *  attributed. Lets the wizard skip asking which tools you use, which the
	 *  act of connecting one has already answered. */
	toolSlug: string | null;
}

export function stashPendingAuthorization(search: string, toolSlug: string | null): void {
	if (typeof window === "undefined") {
		return;
	}
	try {
		window.sessionStorage.setItem(
			KEY,
			JSON.stringify({ returnTo: `${ROUTES.OAUTH_CONSENT}${search}`, toolSlug }),
		);
	} catch {
		// Storage disabled or full. The user still completes onboarding and
		// lands home, which is exactly where they landed before any of this
		// existed — degraded, not broken.
	}
}

export function peekPendingAuthorization(): PendingAuthorization | null {
	if (typeof window === "undefined") {
		return null;
	}
	try {
		const raw = window.sessionStorage.getItem(KEY);
		if (!raw) {
			return null;
		}

		const parsed: unknown = JSON.parse(raw);
		if (typeof parsed !== "object" || parsed === null) {
			return null;
		}
		if (!("returnTo" in parsed) || typeof parsed.returnTo !== "string") {
			return null;
		}
		// sessionStorage is same-origin writable, so this is untrusted input on
		// the way out rather than trusted because we put it there. Requiring the
		// consent path also rejects `//evil.com/...` and absolute URLs, which is
		// the open-redirect `safe-return-to.ts` exists to prevent — here the
		// allowed target is a single known route, so the check is stricter.
		if (!isConsentPath(parsed.returnTo)) {
			return null;
		}

		const toolSlug =
			"toolSlug" in parsed && typeof parsed.toolSlug === "string" ? parsed.toolSlug : null;

		return { returnTo: parsed.returnTo, toolSlug };
	} catch {
		return null;
	}
}

export function clearPendingAuthorization(): void {
	if (typeof window === "undefined") {
		return;
	}
	try {
		window.sessionStorage.removeItem(KEY);
	} catch {
		// Nothing to do, and nothing worth breaking a render over.
	}
}

function isConsentPath(path: string): boolean {
	return path === ROUTES.OAUTH_CONSENT || path.startsWith(`${ROUTES.OAUTH_CONSENT}?`);
}

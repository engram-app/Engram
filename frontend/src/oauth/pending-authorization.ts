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

// A cancel navigates via `window.location.assign`, so the boundary that matters
// is not http-vs-custom-scheme. Native OAuth clients legitimately register
// custom schemes (`cursor://`, `vscode://`, `com.example.app://`) and DCR
// admits them — `cursor://` is documented as observed in prod. Requiring
// http(s) left the Cancel button dead for exactly those clients.
//
// What must never reach `location.assign` is a script-executing scheme. Host
// trust is deliberately NOT decided here; that belongs upstream, against the
// client's registered redirect_uris.
const ABSOLUTE_URI = /^[a-z][a-z0-9+.-]*:/iu;
const SCRIPT_SCHEME = /^(?:javascript|data|vbscript|blob|file):/iu;

// The two screens that can be interrupted by the wizard: OAuth consent, and
// /link for a plugin-first signup. Both sit outside OnboardingGate.
function isResumablePath(path: string): boolean {
	return [ROUTES.OAUTH_CONSENT, ROUTES.DEVICE_LINK].some(
		(route) => path === route || path.startsWith(`${route}?`),
	);
}

function stash(pending: PendingAuthorization): boolean {
	if (typeof window === "undefined") {
		return false;
	}
	try {
		window.sessionStorage.setItem(KEY, JSON.stringify(pending));
		return true;
	} catch {
		// Storage disabled or full (Safari private mode, quota). Landing home
		// after onboarding is degraded but survivable; it is what happened
		// before any of this existed.
		//
		// What is NOT survivable is claiming otherwise. The consent page
		// renders "You'll come straight back here to finish connecting X",
		// and a silently dropped stash turns that sentence into a lie that
		// ends on the dashboard with the waiting client never mentioned
		// again. Hence a return value rather than a swallow.
		return false;
	}
}

export interface PendingAuthorization {
	/** The full consent URL, query string included, so `state` and the PKCE
	 *  challenge survive the detour and the original request is honored. */
	returnTo: string;
	/** Catalog slug of the client being authorized, or null when it cannot be
	 *  attributed. Lets the wizard skip asking which tools you use, which the
	 *  act of connecting one has already answered. */
	toolSlug: string | null;
	/** Display name of the client, so the wizard can say whose authorization
	 *  is waiting instead of dropping the user into an unexplained signup —
	 *  the "preserve context" half of interrupting an OAuth flow. */
	clientName: string | null;
}

/** True when the request was actually parked. Callers MUST NOT promise a
 *  return trip on a false. */
export function stashPendingAuthorization(
	search: string,
	toolSlug: string | null,
	clientName: string | null,
): boolean {
	return stash({ returnTo: `${ROUTES.OAUTH_CONSENT}${search}`, toolSlug, clientName });
}

/** Parks a device-link code (possibly empty) so the wizard returns to /link
 *  with it. There is no OAuth client behind it, so no cancel URL either. */
export function stashPendingDeviceLink(code: string): boolean {
	const returnTo = code
		? `${ROUTES.DEVICE_LINK}?${new URLSearchParams({ code }).toString()}`
		: ROUTES.DEVICE_LINK;
	return stash({ returnTo, toolSlug: null, clientName: "Obsidian" });
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
		if (!isResumablePath(parsed.returnTo)) {
			return null;
		}

		const toolSlug =
			"toolSlug" in parsed && typeof parsed.toolSlug === "string" ? parsed.toolSlug : null;
		const clientName =
			"clientName" in parsed && typeof parsed.clientName === "string" ? parsed.clientName : null;

		return { returnTo: parsed.returnTo, toolSlug, clientName };
	} catch {
		return null;
	}
}

/**
 * Where to send the client when the user abandons setup instead of finishing.
 *
 * OAuth 2.1 expects an interrupted authorization to end in a standards-
 * compliant response, not a tab the user closes: a refusal is `access_denied`
 * carrying the original `state`. Null when there is nothing pending, or when
 * the parked request has no usable redirect — there is nowhere to report to
 * then, and inventing a destination is how an open redirect gets built by
 * accident.
 */
export function pendingCancelUrl(): string | null {
	const pending = peekPendingAuthorization();
	if (!pending) {
		return null;
	}

	const query = new URLSearchParams(pending.returnTo.split("?").slice(1).join("?"));
	const redirectUri = query.get("redirect_uri")?.trim();
	if (!redirectUri) {
		return null;
	}
	if (SCRIPT_SCHEME.test(redirectUri) || !ABSOLUTE_URI.test(redirectUri)) {
		return null;
	}

	const answer = new URLSearchParams({ error: "access_denied" });
	const state = query.get("state");
	if (state) {
		answer.set("state", state);
	}

	return `${redirectUri}${redirectUri.includes("?") ? "&" : "?"}${answer.toString()}`;
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

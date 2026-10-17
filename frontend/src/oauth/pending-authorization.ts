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

// The vault tab consent opens, waiting on `client` to finish connecting. Kept in
// that tab's own sessionStorage, taken from its URL at boot.
const CONNECTING_KEY = "engram:connecting";
// A consent request back from the signup detour, until Approve or Cancel ends it.
const CONSENT_RETURN_KEY = "engram:consent-return";

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
	/** The backend confirmed `redirect_uri` is one the client registered.
	 *  Without it there is no Cancel: the parked query string is anyone's to
	 *  write, so its redirect is an open redirect until proven otherwise. */
	redirectVerified?: boolean;
}

/** True when the request was actually parked. Callers MUST NOT promise a
 *  return trip on a false. */
export function stashPendingAuthorization(
	search: string,
	toolSlug: string | null,
	clientName: string | null,
	redirectVerified = false,
): boolean {
	return stash({
		returnTo: `${ROUTES.OAUTH_CONSENT}${search}`,
		toolSlug,
		clientName,
		redirectVerified,
	});
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

		const redirectVerified = "redirectVerified" in parsed && parsed.redirectVerified === true;

		return { returnTo: parsed.returnTo, toolSlug, clientName, redirectVerified };
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
	if (!pending?.redirectVerified) {
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
	// RFC 9207 §2: error responses carry `iss` too, when the server sent one.
	const iss = query.get("iss");
	if (iss) {
		answer.set("iss", iss);
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

/** `url` marked as the tab consent opened for `client` (a catalog slug). */
export function connectingUrl(url: string, client: string | null, now = Date.now()): string {
	const params = new URLSearchParams({ connecting: String(now) });
	if (client) {
		params.set("client", client);
	}
	return `${url}?${params.toString()}`;
}

/** At boot: keeps this tab's connecting marker and strips it from the URL. */
export function takeConnectingMarker(): void {
	if (typeof window === "undefined") {
		return;
	}
	const url = new URL(window.location.href);
	const since = Number(url.searchParams.get("connecting"));
	if (!since) {
		return;
	}
	const client = url.searchParams.get("client");
	url.searchParams.delete("connecting");
	url.searchParams.delete("client");
	window.history.replaceState(window.history.state, "", `${url.pathname}${url.search}${url.hash}`);
	try {
		window.sessionStorage.setItem(CONNECTING_KEY, JSON.stringify({ since, client }));
	} catch {
		// Storage off: the tab just won't re-check for the connection.
	}
}

/** When this tab was opened by consent and for which client, or null. */
export function connecting(): { since: number; client: string | null } | null {
	try {
		const raw = window.sessionStorage.getItem(CONNECTING_KEY);
		if (!raw) {
			return null;
		}
		const parsed: unknown = JSON.parse(raw);
		if (
			typeof parsed === "object" &&
			parsed !== null &&
			"since" in parsed &&
			typeof parsed.since === "number"
		) {
			const client = "client" in parsed && typeof parsed.client === "string" ? parsed.client : null;
			return { since: parsed.since, client };
		}
		return null;
	} catch {
		return null;
	}
}

export function markConsentReturn(returnTo: string): void {
	try {
		window.sessionStorage.setItem(CONSENT_RETURN_KEY, returnTo);
	} catch {
		// Storage off: a reload of this page just won't open the vault tab.
	}
}

export function consentReturnMarked(returnTo: string): boolean {
	try {
		return window.sessionStorage.getItem(CONSENT_RETURN_KEY) === returnTo;
	} catch {
		return false;
	}
}

export function clearConsentReturn(): void {
	try {
		window.sessionStorage.removeItem(CONSENT_RETURN_KEY);
	} catch {
		// Nothing was stored.
	}
}

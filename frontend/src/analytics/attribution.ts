// Signup attribution: the `?via=` / `utm_*` the marketing site puts on its
// sign-up links, plus the referring domain. Held in tab-scoped sessionStorage
// on the app origin (the exemption the privacy policy claims for crediting a
// referrer), then sent once to the server, which stores it and records it on
// the person. The analytics sanitizer still strips $referrer from every event;
// this explicit, bounded domain is the only referrer that leaves.
//
// The server re-validates everything; the bounds here only keep junk out of
// storage.

import { ApiError, api } from "../api/client";

const KEY = "engram:signup-attribution";
const PARAMS = ["utm_source", "utm_medium", "utm_campaign", "utm_content", "via"] as const;
const MAX = 64;
const TOKEN = /^[A-Za-z0-9._~-]+$/;

type Attribution = Partial<Record<(typeof PARAMS)[number] | "referrer_domain", string>>;

function referrerDomain(referrer: string, ownHost: string): string | null {
	try {
		const host = new URL(referrer).hostname.toLowerCase();
		return host && host !== ownHost.toLowerCase() ? host.slice(0, MAX) : null;
	} catch {
		return null;
	}
}

/** Stash attribution from the sign-up URL. First touch wins: a later visit in
 *  the same tab never overwrites it. */
export function captureSignupAttribution(search: string, referrer: string, ownHost: string): void {
	try {
		if (sessionStorage.getItem(KEY)) {
			return;
		}
		const params = new URLSearchParams(search);
		const found: Attribution = {};
		for (const key of PARAMS) {
			const value = params.get(key)?.slice(0, MAX);
			if (value && TOKEN.test(value)) {
				found[key] = value;
			}
		}
		const domain = referrerDomain(referrer, ownHost);
		if (domain) {
			found.referrer_domain = domain;
		}
		if (Object.keys(found).length > 0) {
			sessionStorage.setItem(KEY, JSON.stringify(found));
		}
	} catch {
		// sessionStorage unavailable (private mode): attribution is optional.
	}
}

/** Send the stash once the user is signed in. Cleared only after the server
 *  accepts it, so a failed request is retried on the next onboarding visit. */
export async function sendSignupAttribution(): Promise<void> {
	let raw: string | null;
	try {
		raw = sessionStorage.getItem(KEY);
	} catch {
		return;
	}
	if (!raw) {
		return;
	}
	try {
		await api.patch("/onboarding/profile", { attribution: JSON.parse(raw) });
		sessionStorage.removeItem(KEY);
	} catch (err) {
		// Kept for a retry, except a 422: the server found nothing usable, and
		// that answer will not change.
		if (err instanceof ApiError && err.status === 422) {
			sessionStorage.removeItem(KEY);
		}
	}
}

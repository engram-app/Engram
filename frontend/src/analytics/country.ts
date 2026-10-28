import { setCountry } from "./identity";

export const COUNTRY_CODE = /^[A-Z]{2}$/;

/** Ask the first-party proxy (worker/index.ts) which country the visitor is in
 *  and hand it to PostHog. Never throws: a missing country is a data gap. */
export async function reportCountry(apiHost: string): Promise<void> {
	try {
		const res = await fetch(`${apiHost}/country`, { credentials: "omit" });
		if (!res.ok || res.status === 204) {
			return;
		}
		const body: unknown = await res.json();
		if (body && typeof body === "object" && "country" in body) {
			const { country } = body;
			if (typeof country === "string" && COUNTRY_CODE.test(country)) {
				setCountry(country);
			}
		}
	} catch {
		// Offline, blocked or malformed: no country, nothing else affected.
	}
}

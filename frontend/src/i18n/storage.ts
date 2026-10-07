import { isMember } from "../lib/is-member";
import { LOCALES, type Locale } from "./locales";

const KEY = "engram:locale";

export function getStoredLocale(): Locale | null {
	try {
		const raw = window.localStorage.getItem(KEY);
		if (isMember(LOCALES, raw)) {
			return raw;
		}
	} catch {
		// localStorage may throw in private mode or sandboxed contexts
	}
	return null;
}

export function setStoredLocale(locale: Locale): void {
	try {
		window.localStorage.setItem(KEY, locale);
	} catch {
		// best-effort; the pick still applies for this session
	}
}

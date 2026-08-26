import { isMember } from "../lib/is-member";

const KEY = "engram:theme";
const VALID: readonly ThemeChoice[] = ["system", "light", "dark"];

export type ThemeChoice = "system" | "light" | "dark";

export function getStoredTheme(): ThemeChoice {
	try {
		const raw = window.localStorage.getItem(KEY);
		if (isMember(VALID, raw)) {
			return raw;
		}
	} catch {
		// localStorage may throw in private mode or sandboxed contexts
	}
	return "system";
}

export function setStoredTheme(choice: ThemeChoice): void {
	try {
		window.localStorage.setItem(KEY, choice);
	} catch {
		// best-effort; ignore failures
	}
}

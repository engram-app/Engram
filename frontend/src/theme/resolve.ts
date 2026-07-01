import type { ThemeChoice } from "./storage";

export type ResolvedTheme = "light" | "dark";

export function getSystemPreference(): ResolvedTheme {
	if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
		return "light";
	}
	return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function resolveTheme(choice: ThemeChoice, systemPref: ResolvedTheme): ResolvedTheme {
	return choice === "system" ? systemPref : choice;
}

export function applyThemeClass(resolved: ResolvedTheme): void {
	const root = document.documentElement;
	if (resolved === "dark") {
		root.classList.add("dark");
	} else {
		root.classList.remove("dark");
	}
}

import type { ReactNode } from "react";
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { applyThemeClass, getSystemPreference, type ResolvedTheme, resolveTheme } from "./resolve";
import { getStoredTheme, setStoredTheme, type ThemeChoice } from "./storage";

interface ThemeContextValue {
	theme: ThemeChoice;
	resolved: ResolvedTheme;
	setTheme: (next: ThemeChoice) => void;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

export function ThemeProvider({ children }: { children: ReactNode }) {
	const [theme, setThemeState] = useState<ThemeChoice>(() => getStoredTheme());
	const [systemPref, setSystemPref] = useState<ResolvedTheme>(() => getSystemPreference());

	const resolved = useMemo(() => resolveTheme(theme, systemPref), [theme, systemPref]);

	useEffect(() => {
		applyThemeClass(resolved);
	}, [resolved]);

	useEffect(() => {
		if (theme !== "system") {
			return;
		}
		if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
			return;
		}

		const mql = window.matchMedia("(prefers-color-scheme: dark)");
		const handler = (e: MediaQueryListEvent) => setSystemPref(e.matches ? "dark" : "light");

		setSystemPref(mql.matches ? "dark" : "light");
		mql.addEventListener("change", handler);
		return () => mql.removeEventListener("change", handler);
	}, [theme]);

	const setTheme = useCallback((next: ThemeChoice) => {
		setStoredTheme(next);
		setThemeState(next);
	}, []);

	const value = useMemo(() => ({ theme, resolved, setTheme }), [theme, resolved, setTheme]);
	return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>;
}

export function useTheme(): ThemeContextValue {
	const ctx = useContext(ThemeContext);
	if (!ctx) {
		throw new Error("useTheme must be used within ThemeProvider");
	}
	return ctx;
}

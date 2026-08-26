import type { ReactNode } from "react";
import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import { useMediaQuery } from "../hooks/use-media-query";
import { applyThemeClass, PREFERS_DARK, type ResolvedTheme, resolveTheme } from "./resolve";
import { getStoredTheme, setStoredTheme, type ThemeChoice } from "./storage";

interface ThemeContextValue {
	theme: ThemeChoice;
	resolved: ResolvedTheme;
	setTheme: (next: ThemeChoice) => void;
}

const ThemeContext = createContext<ThemeContextValue | null>(null);

export function ThemeProvider({ children }: { children: ReactNode }) {
	const [theme, setThemeState] = useState<ThemeChoice>(() => getStoredTheme());
	// matchMedia is an external store, so it is read during render rather than
	// mirrored into state by an effect. resolveTheme ignores systemPref unless
	// the choice is "system", so subscribing unconditionally costs one listener
	// and removes a re-subscribe on every theme toggle.
	const systemPref: ResolvedTheme = useMediaQuery(PREFERS_DARK) ? "dark" : "light";

	const resolved = useMemo(() => resolveTheme(theme, systemPref), [theme, systemPref]);

	useEffect(() => {
		applyThemeClass(resolved);
	}, [resolved]);

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

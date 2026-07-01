import { createContext, useContext, type ReactNode } from "react";
import type { EngramConfig } from "./config";

// Exported so non-component utilities (or test helpers) can read the raw
// context without the throw-on-missing-provider guard `useConfig()` has.
// 99% of consumers should use `useConfig()` — only reach for this when
// you genuinely have a fallback path for the missing-provider case.
export const ConfigContext = createContext<EngramConfig | null>(null);

export function ConfigProvider({
	config,
	children,
}: {
	config: EngramConfig;
	children: ReactNode;
}) {
	return <ConfigContext.Provider value={config}>{children}</ConfigContext.Provider>;
}

// Throws if invoked outside <ConfigProvider> rather than returning a
// silent default — a missing provider is a wiring bug, and a real value
// here is load-bearing for auth provider selection / api-base URL
// composition. Better to crash loud at the offending component than to
// silently route through "selfhost defaults" in saas builds.
export function useConfig(): EngramConfig {
	const ctx = useContext(ConfigContext);
	if (!ctx) {
		throw new Error(
			"useConfig() called outside <ConfigProvider>. Mount ConfigProvider at the app root.",
		);
	}
	return ctx;
}

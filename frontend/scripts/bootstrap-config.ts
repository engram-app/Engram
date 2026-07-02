// frontend/scripts/bootstrap-config.ts
// Single source of truth for the saas runtime config shape, derived from
// VITE_*-style env vars at build time. Consumed by:
//   - write-config-json.ts  → emits dist/config.json (fetch fallback)
//   - vite.config.ts        → inlines window.__ENGRAM_CONFIG__ into index.html
//     so the SPA resolves config synchronously (no /config.json round trip
//     before first render).
// Keep this the ONLY place the saas env→config mapping lives.

type Env = Record<string, string | undefined>;

export interface BootstrapConfig {
	authProvider: string;
	clerkPublishableKey: string;
	billingEnabled: boolean;
	clerkWaitlistMode: boolean;
	apiBase: string;
	wsBase: string;
}

export function bootstrapConfigFromEnv(env: Env): {
	config: BootstrapConfig;
	errors: string[];
} {
	const config: BootstrapConfig = {
		authProvider: env.VITE_AUTH_PROVIDER ?? "clerk",
		clerkPublishableKey: env.VITE_CLERK_PUBLISHABLE_KEY ?? "",
		billingEnabled: env.VITE_BILLING_ENABLED === "true",
		clerkWaitlistMode: env.VITE_CLERK_WAITLIST_MODE === "true",
		apiBase: env.VITE_API_BASE ?? "",
		wsBase: env.VITE_WS_BASE ?? "",
	};

	const errors: string[] = [];
	if (!config.clerkPublishableKey) {
		errors.push("VITE_CLERK_PUBLISHABLE_KEY required for saas build");
	}
	if (!(config.apiBase && config.wsBase)) {
		errors.push("VITE_API_BASE and VITE_WS_BASE required for saas build");
	}

	return { config, errors };
}

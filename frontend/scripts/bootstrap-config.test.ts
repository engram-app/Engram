import { describe, expect, it } from "vitest";
import { bootstrapConfigFromEnv } from "./bootstrap-config";

const SAAS_ENV = {
	VITE_AUTH_PROVIDER: "clerk",
	VITE_CLERK_PUBLISHABLE_KEY: "pk_live_x",
	VITE_BILLING_ENABLED: "true",
	VITE_CLERK_WAITLIST_MODE: "false",
	VITE_API_BASE: "https://api.engram.page",
	VITE_WS_BASE: "wss://api.engram.page",
};

describe("bootstrapConfigFromEnv", () => {
	it("maps a complete saas env to a config object with no errors", () => {
		const { config, errors } = bootstrapConfigFromEnv(SAAS_ENV);
		expect(errors).toEqual([]);
		expect(config).toEqual({
			authProvider: "clerk",
			clerkPublishableKey: "pk_live_x",
			billingEnabled: true,
			clerkWaitlistMode: false,
			apiBase: "https://api.engram.page",
			wsBase: "wss://api.engram.page",
		});
	});

	it("defaults authProvider to clerk (saas builds are always clerk)", () => {
		const { config } = bootstrapConfigFromEnv({ ...SAAS_ENV, VITE_AUTH_PROVIDER: undefined });
		expect(config.authProvider).toBe("clerk");
	});

	it("coerces billingEnabled/clerkWaitlistMode to strict booleans", () => {
		const { config } = bootstrapConfigFromEnv({
			...SAAS_ENV,
			VITE_BILLING_ENABLED: "false",
			VITE_CLERK_WAITLIST_MODE: "true",
		});
		expect(config.billingEnabled).toBe(false);
		expect(config.clerkWaitlistMode).toBe(true);
	});

	it("reports a missing clerk publishable key", () => {
		const { errors } = bootstrapConfigFromEnv({
			...SAAS_ENV,
			VITE_CLERK_PUBLISHABLE_KEY: undefined,
		});
		expect(errors).toContain("VITE_CLERK_PUBLISHABLE_KEY required for saas build");
	});

	it("reports missing api/ws base urls", () => {
		const { errors } = bootstrapConfigFromEnv({
			...SAAS_ENV,
			VITE_API_BASE: undefined,
			VITE_WS_BASE: undefined,
		});
		expect(errors).toContain("VITE_API_BASE and VITE_WS_BASE required for saas build");
	});
});

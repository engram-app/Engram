import { describe, expect, it } from "vitest";
import { isReservedSlug, RESERVED_SLUGS } from "./reserved-slugs";

describe("isReservedSlug", () => {
	it("rejects reserved slugs regardless of case or padding", () => {
		expect(isReservedSlug("settings")).toBe(true);
		expect(isReservedSlug("Settings")).toBe(true);
		expect(isReservedSlug("  link  ")).toBe(true);
	});

	it("rejects the backend deny-listed prefixes too (Task 7)", () => {
		expect(isReservedSlug("assets")).toBe(true);
		expect(isReservedSlug("email")).toBe(true);
		expect(isReservedSlug("socket")).toBe(true);
		expect(isReservedSlug("webhooks")).toBe(true);
		expect(isReservedSlug(".well-known")).toBe(true);
	});

	it("rejects the metrics slug the PromEx forward 401s on", () => {
		expect(isReservedSlug("metrics")).toBe(true);
	});

	it("accepts ordinary slugs", () => {
		expect(isReservedSlug("work")).toBe(false);
		expect(isReservedSlug("settings-archive")).toBe(false);
	});

	it("exports the raw list for consumers that need it directly", () => {
		expect(RESERVED_SLUGS).toContain("settings");
		expect(RESERVED_SLUGS.length).toBeGreaterThan(0);
	});

	// Pins the exact 18-entry list. Written as a literal, not derived from
	// RESERVED_SLUGS, so a deleted entry breaks this test instead of silently
	// passing. Mirrored 1:1 in vault_test.exs (Elixir) - a human dropping an
	// entry from either list must edit both and notice.
	it("the reserved list is exactly this set", () => {
		expect(RESERVED_SLUGS).toEqual([
			"sign-in",
			"sign-up",
			"waitlist",
			"link",
			"oauth",
			"onboard",
			"reset-password",
			"note",
			"search",
			"billing",
			"settings",
			"api",
			"webhooks",
			".well-known",
			"assets",
			"email",
			"socket",
			"metrics",
		]);
	});
});

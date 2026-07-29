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

	it("accepts ordinary slugs", () => {
		expect(isReservedSlug("work")).toBe(false);
		expect(isReservedSlug("settings-archive")).toBe(false);
	});

	it("exports the raw list for consumers that need it directly", () => {
		expect(RESERVED_SLUGS).toContain("settings");
		expect(RESERVED_SLUGS.length).toBeGreaterThan(0);
	});
});

import { describe, expect, it } from "vitest";
import { planCopy } from "./plan-cards";

// The cards state the note caps the backend enforces (`/billing/config`
// `plan_limits`): main's until the v5 go flag is on, never ahead of it.
describe("planCopy", () => {
	it("states main's caps for legacy, and while the config is loading", () => {
		for (const limits of ["legacy", undefined] as const) {
			const { freeTier, catalog } = planCopy(limits);
			expect(freeTier.summary).toBe("3,000 notes · 20 AI searches a day · 1 vault");
			expect(freeTier.features[0]).toBe("3,000 notes, all searchable");
			expect(catalog.starter.features).not.toContain("20,000 notes");
			expect(catalog.pro.features).not.toContain("40,000 notes");
		}
	});

	it("states the v5 caps once the backend enforces them", () => {
		const { freeTier, catalog } = planCopy("v5");
		expect(freeTier.summary).toBe("2,000 notes · 20 AI searches a day · 1 vault");
		expect(freeTier.features[0]).toBe("2,000 notes, all searchable");
		expect(catalog.starter.features[0]).toBe("20,000 notes");
		expect(catalog.pro.features).toContain("40,000 notes");
	});
});

import { describe, expect, it } from "vitest";
import { FREE_TIER, PLAN_CATALOG } from "./plan-cards";

// The cards state the note caps the backend enforces (`LimitKeys` defaults).
describe("plan copy", () => {
	it("states the plan note caps", () => {
		expect(FREE_TIER.summary).toBe("2,000 notes · 20 AI searches a day · 1 vault");
		expect(FREE_TIER.features[0]).toBe("2,000 notes, all searchable");
		expect(PLAN_CATALOG.starter.features[0]).toBe("20,000 notes");
		expect(PLAN_CATALOG.pro.features).toContain("40,000 notes");
	});
});

import { describe, expect, it } from "vitest";
import { buildSettingsSections } from "./sections";

describe("buildSettingsSections", () => {
	it("includes Account first for local auth", () => {
		const sections = buildSettingsSections("local", false, false);
		expect(sections[0]).toMatchObject({ key: "account", label: "Account" });
		expect(sections.map((s) => s.key)).toContain("vaults");
		expect(sections.map((s) => s.key)).toContain("connections");
	});

	it("includes Account first for clerk", () => {
		const sections = buildSettingsSections("clerk", true, false);
		expect(sections[0]).toMatchObject({ key: "account", label: "Account" });
		expect(sections.map((s) => s.key)).toContain("billing");
		expect(sections.map((s) => s.key)).toContain("connections");
	});

	it("omits Billing when billing is disabled (self-host)", () => {
		const sections = buildSettingsSections("local", false, false);
		expect(sections.map((s) => s.key)).not.toContain("billing");
	});

	it("keeps Account but drops Billing for clerk with billing disabled", () => {
		const sections = buildSettingsSections("clerk", false, false);
		expect(sections.map((s) => s.key)).toEqual(["account", "vaults", "connections"]);
	});

	it("appends Administration for local admins", () => {
		const sections = buildSettingsSections("local", false, true);
		expect(sections.map((s) => s.key)).toContain("admin");
	});

	// Guards the omission case: a section pushed without an icon. Only
	// `toBeDefined` — a lucide icon is a forwardRef *object*, not a function,
	// so a typeof check would be asserting the wrong thing. That it actually
	// renders is covered in settings-layout.test.tsx, where the nav is mounted.
	// Billing + admin are on so every branch is built in a single pass.
	it("gives every section an icon", () => {
		const sections = buildSettingsSections("local", true, true);
		expect(sections.map((s) => s.key)).toEqual([
			"account",
			"vaults",
			"connections",
			"billing",
			"admin",
		]);
		for (const s of sections) {
			expect(s.icon, `section "${s.key}" has no icon`).toBeDefined();
		}
	});

	it("does not include Administration for clerk", () => {
		const sections = buildSettingsSections("clerk", true, true);
		expect(sections.map((s) => s.key)).not.toContain("admin");
	});
});

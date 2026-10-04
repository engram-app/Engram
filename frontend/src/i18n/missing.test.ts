import { describe, expect, it } from "vitest";
import { findMissing } from "./missing";

const entries = [
	{ key: "Save" },
	{ key: "{count} files", plural: { one: "{count} file", other: "{count} files" } },
];

describe("findMissing", () => {
	it("reports every entry for an empty catalog, with plural forms", () => {
		expect(findMissing(entries, { de: {} })).toEqual({
			total: 2,
			missing: { de: entries },
		});
	});
	it("omits translated keys per locale", () => {
		const { missing } = findMissing(entries, { de: { Save: "Speichern" }, fr: {} });
		expect(missing.de).toEqual([entries[1]]);
		expect(missing.fr).toHaveLength(2);
	});
	it("reports nothing when complete, and handles no entries", () => {
		const full = { Save: "x", "{count} files": { other: "y" } };
		expect(findMissing(entries, { de: full }).missing.de).toEqual([]);
		expect(findMissing([], { de: {} })).toEqual({ total: 0, missing: { de: [] } });
	});
});

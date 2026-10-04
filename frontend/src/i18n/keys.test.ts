import { describe, expect, it } from "vitest";
import { findProblems, usedEntries, usedKeys } from "./keys-scan";
import type { Catalog } from "./translate";

describe("findProblems (self-check)", () => {
	const used = new Set(["Hello {name}", "{count} files"]);
	it("passes a clean catalog set", () => {
		const catalogs = {
			de: { "Hello {name}": "Hallo {name}" },
			fr: { "Hello {name}": "Bonjour {name}" },
		};
		expect(findProblems(used, catalogs)).toEqual([]);
	});
	it("flags an orphan key", () => {
		expect(findProblems(used, { de: { Typo: "x" } })).toEqual(['de: orphan key "Typo"']);
	});
	it("flags a dropped placeholder", () => {
		expect(findProblems(used, { de: { "Hello {name}": "Hallo" } })).toEqual([
			'de: placeholder mismatch in "Hello {name}"',
		]);
	});
	it("flags an invented placeholder", () => {
		expect(findProblems(used, { de: { "Hello {name}": "Hallo {who}" } })).toEqual([
			'de: placeholder mismatch in "Hello {name}"',
		]);
	});
	it("lets a plural form omit {count} but not invent one", () => {
		expect(
			findProblems(used, { ja: { "{count} files": { one: "1 file", other: "{count} files" } } }),
		).toEqual([]);
		expect(findProblems(used, { ja: { "{count} files": { other: "{n} files" } } })).toHaveLength(1);
	});
	it("flags a key missing from another locale", () => {
		const catalogs = { de: { "Hello {name}": "Hallo {name}" }, fr: {} };
		expect(findProblems(used, catalogs)).toEqual(['fr: missing key "Hello {name}"']);
	});
});

describe("usedKeys (self-check)", () => {
	it("finds t(), tn() and Trans keys, including escapes", () => {
		const src = `
			t("Hello {name}", { name })
			tn({ one: "{count} file", other: "{count} files" }, n)
			<Trans text="Type {w}" slots={{}} />
			t("Say \\"hi\\"")
		`;
		expect([...usedKeys([src])].sort()).toEqual(
			["Hello {name}", "{count} files", "Type {w}", 'Say "hi"'].sort(),
		);
	});
	it("finds msg() keys", () => {
		const src = `const ITEMS = [{ label: msg("Settings") }, msg("Say \\"hi\\"")]`;
		expect([...usedKeys([src])].sort()).toEqual(['Say "hi"', "Settings"].sort());
	});
	it("finds a multi-line tn object", () => {
		const src = `tn(
			{
				one: "{count} note",
				other: "{count} notes",
			},
			n,
		)`;
		expect([...usedKeys([src])]).toEqual(["{count} notes"]);
	});
	it("finds an escaped-quote key", () => {
		expect([...usedKeys([`t("A \\"quoted\\" word")`])]).toEqual(['A "quoted" word']);
	});
});

describe("usedEntries (self-check)", () => {
	it("returns the one form beside other for a counted string", () => {
		const src = `tn({ one: "{count} file", other: "{count} files" }, n)`;
		expect(usedEntries([src])).toEqual([
			{ key: "{count} files", plural: { one: "{count} file", other: "{count} files" } },
		]);
	});
	it("handles other before one and a plural with no one", () => {
		expect(usedEntries([`tn({ other: "{count} b", one: "{count} a" }, n)`])).toEqual([
			{ key: "{count} b", plural: { one: "{count} a", other: "{count} b" } },
		]);
		expect(usedEntries([`tn({ other: "{count} c" }, n)`])).toEqual([
			{ key: "{count} c", plural: { other: "{count} c" } },
		]);
	});
	it("returns plain entries without plural and dedupes", () => {
		expect(usedEntries([`t("A") msg("A") t("B")`])).toEqual([{ key: "A" }, { key: "B" }]);
	});
});

describe("repo catalogs", () => {
	const sources = Object.values(
		import.meta.glob<string>(["../**/*.{ts,tsx}", "!../**/*.test.*", "!../i18n/locale/**"], {
			query: "?raw",
			import: "default",
			eager: true,
		}),
	);
	const catalogs = Object.fromEntries(
		Object.entries(import.meta.glob<{ default: Catalog }>("./locale/*.ts", { eager: true })).map(
			([path, mod]) => [path.slice("./locale/".length, -".ts".length), mod.default],
		),
	);

	it("ships a catalog for every non-English locale", () => {
		expect(Object.keys(catalogs).sort()).toEqual(
			["de", "es", "fr", "it", "ja", "ko", "pt-BR", "ru", "zh-CN", "zh-TW"].sort(),
		);
	});
	it("has no orphan keys, dropped placeholders, or cross-locale gaps", () => {
		expect(findProblems(usedKeys(sources), catalogs)).toEqual([]);
	});
});

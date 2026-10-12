import { describe, expect, it } from "vitest";
import { GLOSSARY_KEYS } from "./auto-translate";
import { findProblems, hiddenCalls, usedEntries, usedKeys } from "./keys-scan";
import { LOCALES } from "./locales";
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

describe("hiddenCalls (self-check)", () => {
	it("flags ref and member calls with a literal argument", () => {
		expect(hiddenCalls(`toast(tRef.current("Oops"))`)).toHaveLength(1);
		expect(hiddenCalls(`translateRef.current("Oops")`)).toHaveLength(1);
		expect(hiddenCalls(`ctx.tn({ one: "a", other: "b" }, n)`)).toHaveLength(1);
		expect(hiddenCalls(`ctx.msg("Oops")`)).toHaveLength(1);
		expect(hiddenCalls(`setError(tLater("Oops"))`)).toHaveLength(1);
	});
	it("ignores plain calls and ref forwarding", () => {
		expect(hiddenCalls(`t("Oops") tn({ other: "b" }, n) tRef.current(en, vars) x.t(key)`)).toEqual(
			[],
		);
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
		expect(Object.keys(catalogs).sort()).toEqual(LOCALES.filter((l) => l !== "en").sort());
	});
	it("has no translator call the scanner cannot see", () => {
		expect(sources.flatMap(hiddenCalls)).toEqual([]);
	});
	// Shipped UI source: src/dev is DEV-only, same carve-out as the noJsxLiterals override.
	const shipped = Object.values(
		import.meta.glob<string>(
			["../**/*.{ts,tsx}", "!../**/*.test.*", "!../dev/**", "!../i18n/locale/**"],
			{
				query: "?raw",
				import: "default",
				eager: true,
			},
		),
	);
	// Biome's noJsxLiterals only sees text children; its noStrings mode would flag every className.
	it("has no raw English in user-facing attributes", () => {
		const allowed = new Set(["Engram", "XXXX-XXXX"]);
		const raw = shipped.flatMap((s) =>
			[
				...s.matchAll(
					/\b(?:placeholder|aria-label|aria-description|title|alt|label)="(?<text>[^"]*\p{L}{2}[^"]*)"/gu,
				),
			]
				.map((m) => m.groups?.text ?? "")
				.filter((text) => !allowed.has(text)),
		);
		expect(raw).toEqual([]);
	});

	// Text that reaches the user without JSX: toasts, inline errors, browser dialogs, the tab title.
	it("has no raw English passed to toasts, errors or dialogs", () => {
		const raw = shipped.flatMap((s) =>
			[
				...s.matchAll(
					/(?:\btoast(?:\.\w+)?|\bset(?:Error|Message)|\b(?:window\.)?(?:confirm|alert))\(\s*"(?<text>[^"]*\p{L}{2}[^"]*)"|document\.title\s*=\s*"(?<title>[^"]*\p{L}{2}[^"]*)"/gu,
				),
			].map((m) => m.groups?.text ?? m.groups?.title ?? ""),
		);
		expect(raw).toEqual([]);
	});
	// A glossary term that is not a real key is never looked up, so its translation
	// floats: "Notes" (not a key) let ja render "note" as both ノート and メモ.
	it("pins only glossary terms that are real keys", () => {
		const used = usedKeys(sources);
		expect(GLOSSARY_KEYS.filter((k) => !used.has(k))).toEqual([]);
	});
	it("has no orphan keys, dropped placeholders, or cross-locale gaps", () => {
		expect(findProblems(usedKeys(sources), catalogs)).toEqual([]);
	});
});

import { describe, expect, it } from "vitest";
import { hiddenCalls, scannedFiles, usedEntries, usedKeys } from "./keys-scan";
import { profile } from "./translate-profile";

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
	it("finds a Trans key after a slot holding an element", () => {
		const src = `<Trans slots={{ b: <b className="x" /> }} text="Type {b} now" />`;
		expect([...usedKeys([src])]).toEqual(["Type {b} now"]);
	});
	it("does not pair a Trans with a later element's text", () => {
		const src = `<Trans text={intro} slots={{}} /> <Other text="Not a key" />`;
		expect([...usedKeys([src])]).toEqual([]);
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
	it("keeps a one form a later call of the same plural omits", () => {
		const first = `tn({ one: "{count} item", other: "{count} items" }, n)`;
		const later = `tn({ other: "{count} items" }, n)`;
		expect(usedEntries([first, later])).toEqual([
			{ key: "{count} items", plural: { one: "{count} item", other: "{count} items" } },
		]);
	});
});

describe("scannedFiles", () => {
	it("keeps source files in sorted order, whatever order readdir returned", () => {
		const listed = ["b.tsx", "a/z.ts", "a/b.ts", "A.ts"];
		expect(scannedFiles(listed)).toEqual(["A.ts", "a/b.ts", "a/z.ts", "b.tsx"]);
		expect(scannedFiles([...listed].reverse())).toEqual(scannedFiles(listed));
	});
	it("drops tests, locale catalogs and non-TS files", () => {
		expect(
			scannedFiles(["x.test.ts", "i18n/locale/de.ts", "i18n\\locale\\fr.ts", "y.css", "", "z.ts"]),
		).toEqual(["z.ts"]);
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
	// The key scanner reads double-quoted literals only, and tn() only as an inline object.
	it("flags keys the scanner cannot read", () => {
		expect(hiddenCalls(`t('Click "Save"')`)).toHaveLength(1);
		const dollar = "$";
		expect(hiddenCalls(`t(\`Hello ${dollar}{name}\`)`)).toHaveLength(1);
		expect(hiddenCalls("t(`Hello`)")).toHaveLength(1);
		expect(hiddenCalls("tn(FORMS, n)")).toHaveLength(1);
		expect(hiddenCalls("msg(label)")).toHaveLength(1);
		expect(hiddenCalls(`msg('Settings')`)).toHaveLength(1);
		expect(hiddenCalls(`<Trans text='Hi {b}' slots={{}} />`)).toHaveLength(1);
		expect(hiddenCalls(`<Trans text={"Hi {b}"} slots={{}} />`)).toHaveLength(1);
		expect(hiddenCalls("<Trans text={`Hi {b}`} slots={{}} />")).toHaveLength(1);
	});
	it("allows a MsgKey variable where the type system checks it", () => {
		expect(hiddenCalls("t(label) t(LABELS[k], { n }) <Trans text={intro} slots={{}} />")).toEqual(
			[],
		);
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
		expect(profile.glossary.filter((k) => !used.has(k))).toEqual([]);
	});
	it("describes only real keys", () => {
		const used = usedKeys(sources);
		expect(Object.keys(profile.descriptions ?? {}).filter((k) => !used.has(k))).toEqual([]);
	});
	it("pins only overrides that are real keys", () => {
		const used = usedKeys(sources);
		const pins = Object.values(profile.pinned ?? {}).flat();
		expect(pins.filter((k) => !used.has(k))).toEqual([]);
	});
});

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { Catalog, LocaleState } from "./core/core";
import { sourceProblems } from "./core/core";
import {
	buildAliases,
	canonicalKey,
	FIELD_KEYS,
	KEY_DESCRIPTIONS,
	KEY_ENTRIES,
	normalizeKey,
} from "./frontmatter-keys";
import { LOCALES } from "./locales";
import { tr } from "./translate-profile";

const TARGETS = LOCALES.filter((l) => l !== "en");
const dir = join(__dirname, "locale", "keys");
const read = (file: string): unknown => JSON.parse(readFileSync(join(dir, file), "utf8"));

describe("frontmatter key aliases", () => {
	const aliases = buildAliases(
		{ ja: { type: "種類", description: "説明", status: "status" }, "zh-CN": { type: "种类" } },
		["ja", "zh-CN"],
	);

	it("maps the English key in any casing or width", () => {
		expect(canonicalKey("type", aliases)).toBe("type");
		expect(canonicalKey("Type", aliases)).toBe("type");
		expect(canonicalKey("ｔｙｐｅ", aliases)).toBe("type");
	});

	it("maps a localized alias", () => {
		expect(canonicalKey("種類", aliases)).toBe("type");
		expect(canonicalKey("种类", aliases)).toBe("type");
		expect(canonicalKey("説明", aliases)).toBe("description");
	});

	it("leaves user keys and tags alone", () => {
		expect(canonicalKey("mood", aliases)).toBeUndefined();
		expect(canonicalKey("tags", aliases)).toBeUndefined();
		expect(canonicalKey("", aliases)).toBeUndefined();
	});

	it("never lets an alias point an English key at another field", () => {
		const bad = buildAliases({ de: { type: "source", project: "Projekt" } }, ["de"]);
		expect(canonicalKey("source", bad)).toBe("source");
		expect(canonicalKey("Projekt", bad)).toBe("project");
	});

	it("gives a shared word to the first locale in order", () => {
		const shared = buildAliases({ cs: { status: "Stav" }, de: { type: "stav" } }, ["cs", "de"]);
		expect(canonicalKey("stav", shared)).toBe("status");
	});

	it("normalizes with NFKC then lower case", () => {
		expect(normalizeKey("ＴＹＰＥ")).toBe("type");
	});

	it("asks the translator for a key name, per field", () => {
		expect(FIELD_KEYS).not.toContain("tags");
		expect(FIELD_KEYS).toHaveLength(13);
		for (const { key } of KEY_ENTRIES) {
			expect(KEY_DESCRIPTIONS[key]).toMatch(/frontmatter property name/u);
		}
		expect(sourceProblems(KEY_ENTRIES)).toEqual([]);
	});
});

// The gate over the committed key catalogs: the same checks as the web app's.
describe("committed key catalogs", () => {
	const states = read("state.json") as Record<string, LocaleState>;

	it("ships a catalog for every non-English locale", () => {
		const files = readdirSync(dir).filter((f) => f !== "state.json");
		expect(files.sort()).toEqual(TARGETS.map((l) => `${l}.json`).sort());
	});

	it.each(TARGETS)("%s passes the translation checks", (code) => {
		const catalog = read(`${code}.json`) as Catalog;
		expect(tr.catalogProblems(KEY_ENTRIES, catalog, code, states[code])).toEqual([]);
	});
});

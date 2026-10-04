import { describe, expect, it } from "vitest";
import type { Catalog } from "./translate";

const T_CALL = /\bt\(\s*"(?<key>(?:[^"\\]|\\.)*)"/gu;
const TN_CALL = /\btn\(\s*\{(?:"(?:[^"\\]|\\.)*"|[^"}])*?\bother:\s*"(?<key>(?:[^"\\]|\\.)*)"/gu;
const TRANS_PROP = /<Trans\s[^>]*?\btext="(?<key>(?:[^"\\]|\\.)*)"/gu;
const TOKEN = /\{(?<name>\w+)\}/gu;

function tokens(text: string): Set<string> {
	return new Set([...text.matchAll(TOKEN)].map((m) => m.groups?.name ?? ""));
}

function usedKeys(sources: readonly string[]): Set<string> {
	const keys = new Set<string>();
	for (const source of sources) {
		for (const re of [T_CALL, TN_CALL, TRANS_PROP]) {
			for (const match of source.matchAll(re)) {
				const key: unknown = JSON.parse(`"${match.groups?.key ?? ""}"`);
				if (typeof key === "string") {
					keys.add(key);
				}
			}
		}
	}
	return keys;
}

function findProblems(used: Set<string>, catalogs: Record<string, Catalog>): string[] {
	const problems: string[] = [];
	const everyKey = new Set(Object.values(catalogs).flatMap((c) => Object.keys(c)));
	for (const [locale, catalog] of Object.entries(catalogs)) {
		for (const [key, value] of Object.entries(catalog)) {
			if (!used.has(key)) {
				problems.push(`${locale}: orphan key ${JSON.stringify(key)}`);
			}
			const want = tokens(key);
			const forms = typeof value === "string" ? [value] : Object.values(value);
			for (const form of forms) {
				const got = tokens(form);
				const dropped = typeof value === "string" && [...want].some((x) => !got.has(x));
				const invented = [...got].some((x) => !want.has(x));
				if (dropped || invented) {
					problems.push(`${locale}: placeholder mismatch in ${JSON.stringify(key)}`);
				}
			}
		}
		for (const key of everyKey) {
			if (!(key in catalog)) {
				problems.push(`${locale}: missing key ${JSON.stringify(key)}`);
			}
		}
	}
	return problems;
}

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

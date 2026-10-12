import { describe, expect, it } from "vitest";

// untranslated() is the one way to show text as written. Every call site is listed
// here with its reason, so a new one (most often server text: English whatever the
// UI language) fails this test instead of shipping. Keyed `path: argument`.
const ALLOWED = new Map<string, string>([
	[
		"settings/account/clerk-errors.ts: server",
		"Clerk validation text names the rejected field; Clerk ships no stable code list to map",
	],
	["viewer/reference/markdown-syntax.ts: type", "callout type names are the keywords users type"],
]);

// Files where every call is allowed: the translators' own output, after the lookup.
const TRANSLATOR_FILES = new Set(["i18n/translate.ts"]);

// Files whose literal arguments are all brand names, the same in every language.
const BRAND_FILES = new Set(["onboarding/onboarding-tools.ts"]);

const CALL = /(?<!function )\buntranslated\(/gu;

// The argument up to its matching parenthesis, whitespace collapsed.
function argumentAt(code: string, start: number): string {
	let depth = 1;
	let end = start;
	while (end < code.length && depth > 0) {
		const c = code[end];
		depth += c === "(" ? 1 : c === ")" ? -1 : 0;
		end++;
	}
	return code
		.slice(start, end - 1)
		.replace(/\s+/gu, " ")
		.trim();
}

function sites(path: string, source: string): string[] {
	const code = source.replace(/^\s*(?:\/\/|\*|\/\*).*$/gmu, "");
	return [...code.matchAll(CALL)]
		.map((m) => argumentAt(code, m.index + m[0].length))
		.filter(() => !TRANSLATOR_FILES.has(path))
		.filter((arg) => !(BRAND_FILES.has(path) && /^"[^"]*"$/u.test(arg)))
		.map((arg) => `${path}: ${arg}`);
}

describe("sites (self-check)", () => {
	it("lists literal and non-literal arguments, skipping the definition and comments", () => {
		const src = `// untranslated() is documented here
function untranslated(text: string): UIText {
const a = untranslated(e.message);
notify(untranslated("Raw"));`;
		expect(sites("x.ts", src)).toEqual(["x.ts: e.message", 'x.ts: "Raw"']);
	});
	it("skips literal brand names only in a brand file", () => {
		expect(sites("onboarding/onboarding-tools.ts", `label: untranslated("Claude") },`)).toEqual([]);
	});
});

describe("repo source", () => {
	const files = import.meta.glob<string>(
		["../**/*.{ts,tsx}", "!../**/*.test.*", "!../i18n/locale/**"],
		{ query: "?raw", import: "default", eager: true },
	);
	// Same-directory files come back as "./x.ts", the rest as "../dir/x.ts".
	const found = Object.entries(files).flatMap(([path, source]) =>
		sites(path.replace(/^\.\.\//u, "").replace(/^\.\//u, "i18n/"), source),
	);
	it("calls untranslated() only where the allowlist says why", () => {
		expect(found.filter((site) => !ALLOWED.has(site))).toEqual([]);
	});
	it("has no stale allowlist entry", () => {
		expect([...ALLOWED.keys()].filter((site) => !found.includes(site))).toEqual([]);
	});
});

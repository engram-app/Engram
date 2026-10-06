// Pure half of the translation-leak checks: no Playwright, no DOM, unit-tested from
// src/lib/i18n-leaks-core.test.ts (Vitest excludes e2e/). The page-facing half is
// i18n-leaks.ts.

type CatalogLike = Record<string, string | Partial<Record<string, string>>>;

interface KeyMatcher {
	key: string;
	// A key without placeholders is compared by equality, one with them by `pattern`.
	exact: string | null;
	pattern: RegExp | null;
}

interface Leak {
	text: string;
	key: string;
}

const PLACEHOLDER = /\{\w+\}/gu;
const HAS_PLACEHOLDER = /\{\w+\}/u;
const WHITESPACE = /\s+/gu;
const REGEX_SPECIALS = /[.*+?^${}()|[\]\\]/gu;
const URL_TOKEN =
	/\bhttps?:\/\/\S+|\b(?:www\.)?[a-z0-9-]+(?:\.[a-z0-9-]+)*\.(?:com|org|net|io|md|page|ax|dev)\b\S*/giu;
const EMAIL_TOKEN = /[^\s@]+@[^\s@]+\.[^\s@]+/gu;
// Brand and technical names that read the same in every language.
const BRAND_TOKEN = /\b(?:Engram|Obsidian|MCP|API|Paddle|Clerk)\b/gu;
const NUMBER_TOKEN = /\d[\d.,:/-]*/gu;
const LETTER = /\p{L}/u;
const PRINTABLE_ASCII = /^[\x20-\x7e]+$/u;
const WORD = /[A-Za-z]+/gu;

// More than this many words of plain ASCII in a non-Latin locale is suspect.
const SUSPECT_MAX_WORDS = 3;

// Visible English that is not a missed translation. "My Vault" is the name the vault
// step stores for the new vault (DEFAULT_VAULT_NAME in onboard-vault-page.tsx, a
// persisted user-data value), shown verbatim in the sidebar; the catalog entry only
// translates the input's placeholder. The binding consent text on the agreement step
// is English by design too, but it is not a key, so only findSuspectStrings sees it
// (SaaS flow, where that step exists).
const INTENTIONAL_ENGLISH: ReadonlySet<string> = new Set(["My Vault"]);

const NON_LATIN_LOCALES = ["ja", "ko", "ru", "zh-CN", "zh-TW"] as const;

function escapeRegex(text: string): string {
	return text.replace(REGEX_SPECIALS, String.raw`\$&`);
}

export function normalizeText(text: string): string {
	return text.replace(WHITESPACE, " ").trim();
}

// English keys whose catalog entry really translates them. A plural entry is keyed
// by its English `other` form, so the key is the `other` text.
export function translatedKeys(catalog: CatalogLike): string[] {
	return Object.entries(catalog)
		.filter(([key, value]) =>
			typeof value === "string" ? value !== key : Object.values(value).some((form) => form !== key),
		)
		.map(([key]) => normalizeText(key));
}

// Brand names, URLs, e-mail addresses and numbers removed: what is left is the
// language-bearing part of a string.
export function stripAllowed(text: string): string {
	return normalizeText(
		text
			.replace(EMAIL_TOKEN, " ")
			.replace(URL_TOKEN, " ")
			.replace(BRAND_TOKEN, " ")
			.replace(NUMBER_TOKEN, " "),
	);
}

// True when nothing language-bearing is left, so the string cannot be a leak.
export function isAllowed(text: string): boolean {
	return !LETTER.test(stripAllowed(text));
}

export function buildMatchers(keys: readonly string[]): KeyMatcher[] {
	const matchers: KeyMatcher[] = [];
	for (const key of keys) {
		if (isAllowed(key.replace(PLACEHOLDER, ""))) {
			// Nothing but placeholders, brands and numbers: matches anything, proves nothing.
			continue;
		}
		if (!HAS_PLACEHOLDER.test(key)) {
			matchers.push({ key, exact: key, pattern: null });
			continue;
		}
		const body = key
			.split(PLACEHOLDER)
			.map((part) => escapeRegex(part))
			.join("(?:.+?)");
		matchers.push({ key, exact: null, pattern: new RegExp(`^${body}$`, "u") });
	}
	return matchers;
}

// Visible strings that are an English key with a real translation: an untranslated
// wrapped string shown as English.
export function findKeyLeaks(strings: readonly string[], matchers: readonly KeyMatcher[]): Leak[] {
	const exact = new Map(matchers.flatMap((m) => (m.exact === null ? [] : [[m.exact, m.key]])));
	const patterned = matchers.filter((m) => m.pattern !== null);
	const leaks: Leak[] = [];
	for (const text of strings) {
		if (isAllowed(text) || INTENTIONAL_ENGLISH.has(text)) {
			continue;
		}
		const hit = exact.get(text) ?? patterned.find((m) => m.pattern?.test(text))?.key;
		if (hit !== undefined) {
			leaks.push({ text, key: hit });
		}
	}
	return leaks;
}

// Plain-ASCII sentences on a page whose language does not use the Latin script:
// unwrapped English that no catalog lookup could have caught.
export function findSuspectStrings(strings: readonly string[]): string[] {
	return strings.filter((text) => {
		if (!PRINTABLE_ASCII.test(text)) {
			return false;
		}
		return (stripAllowed(text).match(WORD) ?? []).length > SUSPECT_MAX_WORDS;
	});
}

export type { CatalogLike, KeyMatcher, Leak };
export { NON_LATIN_LOCALES };

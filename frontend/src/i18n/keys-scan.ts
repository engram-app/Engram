// Shared by keys.test.ts and scripts/i18n-missing.ts so both agree on which
// catalog keys the source uses. Pure: callers supply the source text.
//
// This module is part of the scanned tree, so its comments must not contain
// literal call sites of the translate function, msg, tn or the Trans element.

interface Entry {
	key: string;
	plural?: { one?: string; other: string };
}

const LITERAL = String.raw`"(?:[^"\\]|\\.)*"`;
const KEY_CALLS = [
	/\bt\(\s*"(?<key>(?:[^"\\]|\\.)*)"/gu,
	/\bmsg\(\s*"(?<key>(?:[^"\\]|\\.)*)"/gu,
	// Up to the element's first text attribute, across slot elements (their `>`) but
	// never past another text attribute or into another Trans.
	/<Trans\s(?:(?!<Trans\b|\btext=)[\s\S])*?\btext="(?<key>(?:[^"\\]|\\.)*)"/gu,
];
const TN_CALL = new RegExp(String.raw`\btn\(\s*\{(?<body>(?:${LITERAL}|[^"}])*)\}`, "gu");
const FORM = /\b(?<name>one|other):\s*"(?<text>(?:[^"\\]|\\.)*)"/gu;

function parseLiteral(raw: string): string {
	const text: unknown = JSON.parse(`"${raw}"`);
	return typeof text === "string" ? text : "";
}

function usedEntries(sources: readonly string[]): Entry[] {
	const entries = new Map<string, Entry>();
	for (const source of sources) {
		for (const re of KEY_CALLS) {
			for (const match of source.matchAll(re)) {
				const key = parseLiteral(match.groups?.key ?? "");
				entries.set(key, entries.get(key) ?? { key });
			}
		}
		for (const call of source.matchAll(TN_CALL)) {
			const forms: Record<string, string> = {};
			for (const form of (call.groups?.body ?? "").matchAll(FORM)) {
				forms[form.groups?.name ?? ""] = parseLiteral(form.groups?.text ?? "");
			}
			const { one, other } = forms;
			if (other !== undefined) {
				entries.set(other, { key: other, plural: one === undefined ? { other } : { one, other } });
			}
		}
	}
	return [...entries.values()];
}

function usedKeys(sources: readonly string[]): Set<string> {
	return new Set(usedEntries(sources).map((e) => e.key));
}

// Translator calls the key scanner cannot see: made through a ref's current value or
// another object's member, with a literal first argument. Such a key is in no catalog.
// The same goes for an aliased translator named like `tLater` (`t` plus a capital).
const HIDDEN_CALL = /(?:\b(?:t|translate)Ref\.current|\w\.(?:t|tn|msg)|\bt[A-Z]\w*)\(\s*["{]/gu;
// Keys the scanner cannot read at all: a single-quoted or template key, a plural
// that is not an inline object, a marker around anything but a double-quoted
// literal, or a Trans text written any way but text="...". A variable key is left
// to tsc, which only accepts one typed as a marked key. Member calls forward a key
// they were given, and a declaration is not a call.
const UNREADABLE_KEY =
	/(?<![.\w]|function )(?:t\(\s*['`]|tn\(\s*(?!\{)[^\s)]|msg\(\s*(?!")[^\s)])|<Trans\s(?:(?!<Trans\b|\btext=)[\s\S])*?\btext=(?:'|\{\s*["'`])/gu;

function hiddenCalls(source: string): string[] {
	return [...source.matchAll(HIDDEN_CALL), ...source.matchAll(UNREADABLE_KEY)].map((m) => m[0]);
}

export type { Entry };
export { hiddenCalls, usedEntries, usedKeys };

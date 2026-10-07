// Shared by keys.test.ts and scripts/i18n-missing.ts so both agree on which
// catalog keys the source uses. Pure: callers supply the source text.
//
// This module is part of the scanned tree, so its comments must not contain
// literal call sites of the translate function, msg, tn or the Trans element.
import type { Catalog } from "./translate";

interface Entry {
	key: string;
	plural?: { one?: string; other: string };
}

const LITERAL = String.raw`"(?:[^"\\]|\\.)*"`;
const KEY_CALLS = [
	/\bt\(\s*"(?<key>(?:[^"\\]|\\.)*)"/gu,
	/\bmsg\(\s*"(?<key>(?:[^"\\]|\\.)*)"/gu,
	/<Trans\s[^>]*?\btext="(?<key>(?:[^"\\]|\\.)*)"/gu,
];
const TN_CALL = new RegExp(String.raw`\btn\(\s*\{(?<body>(?:${LITERAL}|[^"}])*)\}`, "gu");
const FORM = /\b(?<name>one|other):\s*"(?<text>(?:[^"\\]|\\.)*)"/gu;
const TOKEN = /\{(?<name>\w+)\}/gu;

function parseLiteral(raw: string): string {
	const text: unknown = JSON.parse(`"${raw}"`);
	return typeof text === "string" ? text : "";
}

function tokens(text: string): Set<string> {
	return new Set([...text.matchAll(TOKEN)].map((m) => m.groups?.name ?? ""));
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

function hiddenCalls(source: string): string[] {
	return [...source.matchAll(HIDDEN_CALL)].map((m) => m[0]);
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

export type { Entry };
export { findProblems, hiddenCalls, usedEntries, usedKeys };

// Pure half of `scripts/i18n-translate.ts`: prompts for translategemma and the
// checks that decide whether its answer may replace a catalog entry.
import type { Entry } from "./keys-scan";
import type { Locale } from "./locales";
import type { Catalog } from "./translate";

type Target = Exclude<Locale, "en">;

interface Spec {
	name: string;
	tone: string;
	// Register the catalog avoids (the plugin and marketing copy pick one per language).
	formal?: RegExp;
	// A script the answer must contain when the old entry did.
	script?: RegExp;
}

const HAN = /\p{Script=Han}/u;

const SPECS: Record<Target, Spec> = {
	de: {
		name: "German",
		tone: "Address the user informally (du, dein), never Sie.",
		formal: /\b(?:Ihr(?:e[nmrs]?)?|Ihnen)\b|(?<=[\p{Ll},] )Sie\b/u,
	},
	es: {
		name: "Spanish",
		tone: "Address the user informally (tú), never usted. Use neutral Spanish understood in Latin America and Spain.",
		formal: /\busted(?:es)?\b/iu,
	},
	fr: {
		name: "French",
		tone: "Address the user informally (tu, ton), never vous.",
		formal: /\b(?:vous|votre|vos)\b/iu,
	},
	it: {
		name: "Italian",
		tone: "Address the user informally (tu, tuo), never Lei.",
		formal: /\b(?:Lei|Suo|Sua|Suoi|Sue)\b/u,
	},
	ja: {
		name: "Japanese",
		tone: "Use polite, concise UI Japanese.",
		script: /[\p{Script=Hiragana}\p{Script=Katakana}\p{Script=Han}]/u,
	},
	ko: { name: "Korean", tone: "Use polite, concise UI Korean.", script: /\p{Script=Hangul}/u },
	ms: { name: "Malay", tone: "Address the user as anda." },
	"pt-BR": { name: "Brazilian Portuguese", tone: "Address the user as você." },
	ru: {
		name: "Russian",
		tone: "Address the user formally (вы, ваш), never ты.",
		formal: /(?<![\p{L}])(?:ты|твой|твоя|твоё|твои|тебя|тебе)(?![\p{L}])/iu,
		script: /\p{Script=Cyrillic}/u,
	},
	vi: { name: "Vietnamese", tone: "Address the user as bạn." },
	"zh-CN": {
		name: "Simplified Chinese",
		tone: "Use concise Simplified Chinese UI wording.",
		script: HAN,
	},
	"zh-TW": {
		name: "Traditional Chinese",
		tone: "Use concise Traditional Chinese (Taiwan) UI wording.",
		script: HAN,
	},
};

// Terms held fixed across every batch so "vault" is not three different words.
const GLOSSARY_KEYS = [
	"Vaults",
	"Notes",
	"Attachments",
	"Folder",
	"Settings",
	"Search",
	"Manage your profile, password, and account.",
];
const BRANDS = ["Engram", "Obsidian", "MCP", "Paddle", "Clerk", "GitHub", "Claude", "ChatGPT"];
const NEWLINE = "⏎";
const PLACEHOLDER = /\{[^{}]+\}/gu;
const LITERAL = /`[^`]+`|https?:\/\/\S+|[\w.+-]+@[\w-]+\.[\w.]+/gu;
const CJK_STOP = /(?<stop>[。！？])\s+/gu;

function wordCount(s: string): number {
	return s
		.replace(PLACEHOLDER, " ")
		.split(/\s+/u)
		.filter((w) => /\p{L}/u.test(w)).length;
}

// A set, not a count: repeating {name} renders fine; dropping or inventing one does not.
function placeholders(s: string): string[] {
	return [...new Set(s.match(PLACEHOLDER) ?? [])].sort();
}

function buildPrompt(
	code: Target,
	glossary: Record<string, string>,
	text: string,
	multi: boolean,
): string {
	const { name, tone } = SPECS[code];
	const terms = Object.entries(glossary)
		.map(([en, tr]) => `${en} = ${tr}`)
		.join("\n");
	return [
		`You are a professional English (en) to ${name} (${code}) translator localizing the user interface of Engram, a notes app that syncs an Obsidian vault and exposes it to AI assistants.`,
		multi
			? "Each numbered line is a separate UI string. Translate every line independently and return exactly the same numbered lines, one per line, in the same order."
			: "",
		`Rules: keep each string as short as its source. Copy every {placeholder} in curly braces exactly, untranslated. Do not add punctuation a source lacks. Keep brand names (${BRANDS.join(", ")}) unchanged. ${text.includes(NEWLINE) ? `Keep the ${NEWLINE} marker. ` : ""}${tone}`,
		terms ? `Use this established terminology and tone:\n${terms}` : "",
		`Produce only the ${name} translation, without any additional explanations or commentary. Please translate the following English text into ${name}:\n\n\n${text}`,
	]
		.filter(Boolean)
		.join("\n");
}

function cleanOutput(src: string, raw: string, code: Target): string {
	let out = raw.trim();
	const first = out.at(0) ?? "";
	if (
		out.length > 1 &&
		first === out.at(-1) &&
		`"'«»`.includes(first) &&
		!`"'`.includes(src.at(0) ?? "")
	) {
		out = out.slice(1, -1).trim();
	}
	if (!src.includes("\n")) {
		out = out.replaceAll(NEWLINE, "").trim();
	}
	if (!/[.!?…:。]$/u.test(src)) {
		out = out.replace(/[.。．]$/u, "");
	}
	if (code === "ja" || code === "zh-CN" || code === "zh-TW") {
		out = out.replace(CJK_STOP, "$<stop>");
	}
	return out
		.replace(/[ \t]*⏎[ \t]*/gu, "\n")
		.replace(/[ \t]{2,}/gu, " ")
		.trim();
}

// Names of the checks `out` fails as a translation of `src`. `old` is the entry it
// would replace: a register or script the old catalog already used is not new.
function problems(src: string, out: string, code: Target, old?: string): string[] {
	const { formal, script } = SPECS[code];
	const lengthCap = Math.max(3 * src.length, 2.5 * (old ?? src).length) + 15;
	const failed: Record<string, boolean> = {
		empty: out.length === 0,
		placeholders: placeholders(out).join() !== placeholders(src).join(),
		newlines: out.split("\n").length !== src.split("\n").length,
		literal: !(src.match(LITERAL) ?? []).every((lit) => out.includes(lit)),
		brand: !BRANDS.every((b) => !src.includes(b) || out.includes(b)),
		length: out.length > lengthCap,
		register: Boolean(formal?.test(out) && !(old && formal.test(old))),
		// Only sentences: "ID:", "A → Z" or a bare "{status}: {message}" may stay Latin.
		script: Boolean(
			script &&
				wordCount(src) > 3 &&
				!script.test(out) &&
				!(old !== undefined && !script.test(old)),
		),
		untranslated: out === src && old !== undefined && old !== src,
	};
	return Object.keys(failed).filter((name) => failed[name]);
}

function isValid(src: string, out: string, code: Target, old?: string): boolean {
	return problems(src, out, code, old).length === 0;
}

// The model translates placeholder names that are words ({used} -> {digunakan});
// numbered tokens survive, so names are swapped out before sending.
function maskPlaceholders(src: string): { masked: string; names: string[] } {
	const names: string[] = [];
	const masked = src.replace(PLACEHOLDER, (name) => {
		const known = names.indexOf(name);
		const index = known === -1 ? names.push(name) - 1 : known;
		return `{${index}}`;
	});
	return { masked, names };
}

function unmaskPlaceholders(out: string, names: readonly string[]): string {
	return out.replace(
		/\{(?<index>\d+)\}/gu,
		(token, index: string) => names[Number(index)] ?? token,
	);
}

function batchText(keys: readonly string[]): string {
	return keys.map((k, i) => `[${i + 1}] ${k.replaceAll("\n", ` ${NEWLINE} `)}`).join("\n");
}

function parseBatch(response: string, n: number): (string | undefined)[] {
	const out: (string | undefined)[] = Array.from({ length: n }, () => undefined);
	for (const line of response.split("\n")) {
		const m = /^\s*\[?(?<num>\d+)[\].)]\s*(?<text>.*)$/u.exec(line);
		const i = Number(m?.groups?.num) - 1;
		if (m?.groups && i >= 0 && i < n) {
			out[i] = m.groups.text;
		}
	}
	return out;
}

// One number per plural category: translating "5 files" lets the model pick the
// case form, then fromSample() swaps {count} back in.
function pluralSamples(code: Target): { category: Intl.LDMLPluralRule; sample: string }[] {
	const rules = new Intl.PluralRules(code);
	return rules.resolvedOptions().pluralCategories.map((category) => {
		// `one` gets 1; anything else starts at 2, so "1 days" never reaches the model.
		const candidates = category === "one" ? [1] : [];
		for (let n = 2; n <= 200; n++) {
			candidates.push(n);
		}
		const n = candidates.find((c) => rules.select(c) === category);
		if (n !== undefined) {
			return { category, sample: String(n) };
		}
		return { category, sample: "1.5" };
	});
}

function fromSample(out: string, sample: string): string | null {
	const pattern = new RegExp(`(?<![\\d.,])${sample.replace(".", "[.,]")}(?![\\d]|[.,]\\d)`, "gu");
	const hits = out.match(pattern) ?? [];
	return hits.length === 1 ? out.replace(pattern, "{count}") : null;
}

function uniqueKeys(entries: readonly Entry[]): string[] {
	return [...new Set(entries.map((e) => e.key))];
}

function todoKeys(entries: readonly Entry[], catalog: Catalog, all: boolean): string[] {
	return uniqueKeys(entries).filter((k) => all || !(k in catalog));
}

// Source order, fresh over old; a key no longer in the source (an edited or
// removed English string) is dropped, which keeps keys.test.ts free of orphans.
function mergeCatalog(entries: readonly Entry[], old: Catalog, fresh: Catalog): Catalog {
	const merged: Catalog = {};
	for (const key of uniqueKeys(entries)) {
		const value = fresh[key] ?? old[key];
		if (value !== undefined) {
			merged[key] = value;
		}
	}
	return merged;
}

export type { Target };
export {
	batchText,
	buildPrompt,
	cleanOutput,
	fromSample,
	GLOSSARY_KEYS,
	isValid,
	maskPlaceholders,
	mergeCatalog,
	parseBatch,
	pluralSamples,
	problems,
	SPECS,
	todoKeys,
	unmaskPlaceholders,
};

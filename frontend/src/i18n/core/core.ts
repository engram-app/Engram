// i18n-core 79b262f1
// The translategemma pipeline shared by the web app, the Obsidian plugin and the
// marketing site: prompts, the checks an answer must pass, and catalog state.
// Canonical copy: engram-app/Engram frontend/src/i18n/core/. The other repos
// vendor it byte for byte; see README.md here before editing any copy.
// Constraints: no lookbehind (Obsidian's lint bans it), no Node or DOM imports.

type PluralForms = Partial<Record<Intl.LDMLPluralRule, string>>;
type Catalog = Record<string, string | PluralForms>;

interface Entry {
	key: string;
	// A counted string: its key is the English `other` form, `one` the singular.
	plural?: { one?: string };
}

interface Spec {
	name: string;
	tone: string;
	// Register the catalog avoids.
	formal?: RegExp;
	// Script a sentence's translation must contain.
	script?: RegExp;
	// No spaces between words (ja, zh): edge spaces are dropped, not carried over.
	spaceless?: boolean;
}

interface Profile<T extends string> {
	// What is being localized, for the prompt: "localizing <subject>."
	subject: string;
	specs: Record<T, Spec>;
	// Never translated: masked before the model sees them, checked after.
	brands: readonly string[];
	// Terms pinned across every batch. Must be real keys.
	glossary: readonly string[];
	// Per locale, keys kept exactly as committed: a hand override copied from
	// Obsidian's own translation. Never sent to the model, and not part of the
	// fingerprint, so adding one redoes nothing.
	pinned?: Partial<Record<T, readonly string[]>>;
	// A note for the translator on what a string means where it shows, keyed by
	// the English: FormatJS's message `description`, gettext's translator comment.
	// For short labels whose sense the words alone do not fix ("Reading" as a view
	// mode, not loading). Sent with that string alone; a changed one redoes it.
	descriptions?: Readonly<Record<string, string>>;
}

// Per locale, in `locale/state.json`.
interface LocaleState {
	// Fingerprint of the prompt, profile and model digest that built the catalog.
	// A mismatch redoes the locale, so no version needs bumping by hand.
	translator: string;
	// Keys whose answers failed every check, with the day each first failed. They
	// keep the old entry or fall back to English; the gate tolerates only these.
	failed: Record<string, string>;
	// Each plural's English `one` form. A plural's key is its `other` form, so an
	// edit to `one` alone would otherwise leave the old translation in place.
	one?: Record<string, string>;
	// The glossary the catalog was built with: a changed term redoes its sentences.
	glossary?: Record<string, string>;
	// The descriptions it was built with: a changed one redoes its string.
	descriptions?: Record<string, string>;
}

const NEWLINE = "⏎";
const PLACEHOLDER = /\{[^{}]+\}/gu;
// `<name attrs>`, `</name>`, `<name />` in rich-text copy.
const TAG = /<(?<close>\/?)(?<name>[a-zA-Z][\w-]*)\b(?<attrs>[^>]*?)(?<self>\/?)>/gu;
const NUMBERED = /<\/?\d+\s*\/?>|\{\d+\}/u;
const LITERAL = /`[^`]+`|https?:\/\/\S+|[\w.+-]+@[\w-]+\.[\w.]+/gu;
const CJK_STOP = /(?<stop>[。！？])\s+/gu;
// Labels lead with an emoji or a mark ("🔄 Sync Center", "✓ {count} synced"); the
// model sometimes drops one, or pastes a glossary term's emoji into a sentence.
const SYMBOL = /\p{Extended_Pictographic}|[✓✕✔✖•]/gu;
// A middle dot that separates joined parts ("{count} files · 12 MB"), not one
// inside a word ("en·gram", which a language may spell "engrama").
const SEPARATOR_DOT = /(?:^|[^\p{L}])·|·(?:[^\p{L}]|$)/u;
const LEAD = /^[ \t]*/u;
const TRAIL = /[ \t]*$/u;

function escapeRegExp(s: string): string {
	return s.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}

function lead(s: string): string {
	return LEAD.exec(s)?.[0] ?? "";
}

function trail(s: string): string {
	return TRAIL.exec(s)?.[0] ?? "";
}

function symbols(s: string): string {
	const found = s.match(SYMBOL) ?? [];
	return [...new Set(SEPARATOR_DOT.test(s) ? [...found, "·"] : found)].sort().join();
}

// A set, not a count: repeating {name} renders fine; dropping or inventing one does not.
function placeholders(s: string): string[] {
	return [...new Set(s.match(PLACEHOLDER) ?? [])].sort();
}

// Every tag, counted, closing slash of a self-closing tag ignored. Any name, not
// only lowercase ASCII: the model invents "<Engram>" and "<보유한>", which a page
// shows as broken text or swallows as an element.
function tags(s: string): string {
	return [...s.matchAll(/<\/?(?<tag>[^\s<>/]+)[^<>]*>/gu)]
		.map((m) => m[0].replace(/\s*\/?>$/u, ">"))
		.sort()
		.join();
}

// Every number but a lone 1, which a language may spell out ("Eine Notiz"). Digit
// separators are dropped first: "2,000" is "2.000" in German and "2 000" in French.
// For a source, a number fused to a word ("3-way", "2-factor") is skipped too: it is
// part of a compound the translation may spell out ("трёхстороннее").
function numbers(s: string, source = false): string[] {
	const digits = (source ? s.replace(/\d+-(?=\p{L})/gu, "") : s).replace(
		/(?<d>\d)[.,\u00a0\u202f ]+(?=\d)/gu,
		"$<d>",
	);
	return [...new Set(digits.match(/\d+/gu) ?? [])].filter((n) => n !== "1");
}

// Terms a language's own software leaves in English, by base language, so an
// echo of one is a translation and not a miss. Each comes from Obsidian's or VS
// Code's translations for that language (or Clerk's, for its own UI terms); add
// one only with such a source.
// Lowercase, letters only, brands already removed ("💬 Feedback" is "feedback").
const LOANWORDS: Record<string, readonly string[]> = {
	// Names every language keeps, for profiles that do not list them as brands.
	// "cloud" is what "Engram Cloud", a product name, leaves once "Engram" is removed.
	"*": [
		...["chatgpt web", "cloud", "docker compose", "docker compose up", "mcp", "obsidian sync"],
		...["reddit", "relay", "sponsors", "youtube"],
	],
	de: [
		"alternative",
		"backend",
		"browser",
		"clients",
		"cloud",
		"code",
		"community",
		"downloads",
		"faq",
		"feedback",
		"frontmatter",
		"link",
		"links",
		"markdown",
		"name",
		"offline",
		"optional",
		"self host",
		"status",
		"support",
		"system",
		"tag",
		"tags",
		"text",
		"token",
		"upgrade",
		"uploads",
		"vault",
		"vaults",
		"version",
		"web",
	],
	// Obsidian's Czech keeps the first four in English; Clerk's Czech heads its
	// members table "Role".
	cs: ["frontmatter", "markdown", "offline", "role", "text"],
	es: ["error", "idea", "legal", "markdown", "popular", "subtotal", "token", "total", "web"],
	fr: [
		"actions",
		"administration",
		"alternative",
		"clients",
		"code",
		"concepts",
		"date",
		"diagnostics",
		"documentation",
		"exact",
		"faq",
		"markdown",
		"mobile",
		"note",
		"notes",
		"source",
		"structure",
		"support",
		"total",
		"type",
		"types",
		"web",
	],
	// "admin", "bug" and "subtotal" have no Obsidian or VS Code source (no VS Code
	// Indonesian pack); kept on the owner's call, 2026-10-16.
	id: [
		"admin",
		"alias",
		"bookmark",
		"bug",
		"callout",
		"edit",
		"editor",
		"email",
		"file",
		"filter",
		"folder",
		"font",
		"format",
		"info",
		"label",
		"manual",
		"markdown",
		"offline",
		"per",
		"plugin",
		"root",
		"status",
		"subtotal",
		"tag",
		"total",
		"url",
		"vault",
	],
	it: [
		"account",
		"backend",
		"browser",
		"bug",
		"cloud",
		"community",
		"email",
		"feedback",
		"file",
		"frontmatter",
		"idea",
		"markdown",
		"mobile",
		"offline",
		"password",
		"privacy",
		"self host",
		"self hosted",
		"tag",
		"token",
		"uploads",
		"user agent",
		"vault",
		"web",
	],
	ja: ["linux pc", "markdown", "web", "windows pc"],
	ko: ["linux pc", "url", "windows pc"],
	ms: ["edit", "folder", "frontmatter", "idea", "label", "markdown", "popular", "status", "token"],
	pl: [
		"alias",
		"folder",
		"format",
		"link",
		"markdown",
		"offline",
		"status",
		"system",
		"tag",
		"wikilink",
	],
	pt: [
		"backend",
		"bug",
		"cloud",
		"docs",
		"downloads",
		"feedback",
		"frontmatter",
		"legal",
		"link",
		"links",
		"markdown",
		"offline",
		"popular",
		"status",
		"subtotal",
		"tag",
		"tags",
		"token",
		"total",
		"uploads",
		"web",
	],
	ru: ["markdown"],
	tr: ["markdown"],
	// Obsidian's Ukrainian keeps both in English.
	uk: ["frontmatter", "markdown"],
	vi: ["backend", "cloud", "email", "frontmatter", "markdown", "token"],
	zh: ["bug", "markdown"],
};

// True when any of `texts` (a source, and the source without its tokens and
// brands) reads as one listed phrase: "Obsidian Sync" whole, "Feedback" alone.
function isLoanword(code: string, ...texts: string[]): boolean {
	const kept = [...(LOANWORDS["*"] ?? []), ...(LOANWORDS[code.split("-")[0] ?? code] ?? [])];
	return texts.some((text) =>
		kept.includes((text.toLowerCase().match(/\p{L}+/gu) ?? []).join(" ")),
	);
}

function words(s: string): number {
	return s.split(/\s+/u).filter((w) => /\p{L}/u.test(w)).length;
}

// Polynomial rolling hash modulo the largest 32-bit prime. Change detection only,
// never security. Plain arithmetic: h * 131 + c stays far below 2^53.
function hash(s: string): string {
	const PRIME = 4_294_967_291;
	let h = 7;
	for (const ch of s) {
		h = (h * 131 + (ch.codePointAt(0) ?? 0)) % PRIME;
	}
	return h.toString(16).padStart(8, "0");
}

// Line 1 of each core file is `// i18n-core <hash of the rest>`, written by the
// canonical repo's scripts/i18n-core-sync.ts. A copy edited in place fails this.
function coreHeaderOk(text: string): boolean {
	const nl = text.indexOf("\n");
	const head = /^\/\/ i18n-core (?<h>[0-9a-f]{8})$/u.exec(text.slice(0, nl));
	return head?.groups?.h === hash(text.slice(nl + 1));
}

// A plural form that dropped {count} ("eine Datei") is checked against the key
// without it; one that kept it, against the key.
function formSource(key: string, form: string): string {
	if (form.includes("{count}")) {
		return key;
	}
	const bare = key.replaceAll("{count}", "").replace(/\s+/gu, " ").trim();
	return `${lead(key)}${bare}${trail(key)}`;
}

function pluralCategories(code: string): Intl.LDMLPluralRule[] {
	return new Intl.PluralRules(code).resolvedOptions().pluralCategories;
}

// `one` covers only the number 1 (de, es), not 21 or 31 (ru), so its form may
// spell the number out instead of keeping {count}.
function exactOne(code: string): boolean {
	const rules = new Intl.PluralRules(code);
	if (!pluralCategories(code).includes("one") || rules.select(0) === "one") {
		return false;
	}
	for (let n = 2; n <= 200; n++) {
		if (rules.select(n) === "one") {
			return false;
		}
	}
	return true;
}

function translator<T extends string>(profile: Profile<T>) {
	const { specs, brands, glossary } = profile;
	const pinned: Partial<Record<T, readonly string[]>> = profile.pinned ?? {};
	const descriptions = profile.descriptions ?? {};
	// Longest first, so "Engram Vault Sync" wins over "Engram" in the alternation.
	// The `pre` group stands in for a lookbehind: the character before the brand.
	const BRAND_WORD = `(?<pre>^|[^A-Za-z0-9])(?<brand>${[...brands]
		.sort((a, b) => b.length - a.length)
		.map(escapeRegExp)
		.join("|")})(?![A-Za-z0-9])`;
	const MASKABLE = new RegExp(`${PLACEHOLDER.source}|${TAG.source}|${BRAND_WORD}`, "gu");

	// Whole word on the Latin side, so "Pro" is not "Profile" yet "Pro版" counts.
	// `inflected` lets a translation add a possessive or plural s ("Obsidians Stil").
	function hasBrand(s: string, brand: string, inflected = false): boolean {
		const suffix = inflected ? "(?:s|'s|’s)?" : "";
		return new RegExp(`(?:^|[^A-Za-z0-9])${escapeRegExp(brand)}${suffix}(?![A-Za-z0-9])`, "u").test(
			s,
		);
	}

	// Words left once tokens, brands and literals are gone: what there is to translate.
	function prose(s: string): string {
		return s
			.replace(PLACEHOLDER, " ")
			.replace(TAG, " ")
			.replace(LITERAL, " ")
			.replace(new RegExp(BRAND_WORD, "gu"), " ");
	}

	// Nothing to translate: only brand names, placeholders, tags and punctuation.
	// The source is the answer, so no model call.
	function isBrandOnly(src: string): boolean {
		return !/\p{L}/u.test(prose(src));
	}

	function buildPrompt(
		code: T,
		terms: Record<string, string>,
		text: string,
		multi: boolean,
		description?: string,
	): string {
		const { name, tone } = specs[code];
		// Without the emoji: "🔄 Sync Center = 🔄 ..." made the model paste 🔄 into every
		// sentence that mentions the Sync Center.
		const bare = (term: string): string => term.replace(SYMBOL, "").trim();
		const terminology = Object.entries(terms)
			.map(([en, tr]) => `${bare(en)} = ${bare(tr)}`)
			.join("\n");
		// Token rules only when the text has such a token, and never spelled out: the
		// model copied a literal example token into answers that had none.
		const tokenRules = [
			placeholders(text).length > 0
				? "Copy every token in curly braces exactly, untranslated."
				: "",
			/<\/?[\w-]+\s*\/?>/u.test(text)
				? "Keep every token in angle brackets exactly, around the matching words."
				: "",
			text.includes(NEWLINE) ? `Keep the ${NEWLINE} marker.` : "",
		]
			.filter(Boolean)
			.map((r) => `${r} `)
			.join("");
		return [
			`You are a professional English (en) to ${name} (${code}) translator localizing ${profile.subject}.`,
			multi
				? "Each numbered line is a separate string. Translate every line independently and return exactly the same numbered lines, one per line, in the same order."
				: "",
			`Rules: keep each string as short as its source. ${tokenRules}Do not add punctuation a source lacks. Keep brand names (${brands.join(", ")}) unchanged. ${tone}`,
			terminology ? `Use this established terminology and tone:\n${terminology}` : "",
			description ? `Context for this string (do not translate it): ${description}` : "",
			`Produce only the ${name} translation, without any additional explanations or commentary. Please translate the following English text into ${name}:\n\n\n${text}`,
		]
			.filter(Boolean)
			.join("\n");
	}

	function cleanOutput(src: string, raw: string, code: T): string {
		const { spaceless } = specs[code];
		let out = raw.trim();
		// slice, not at(): the plugin compiles against ES2021.
		const first = out.slice(0, 1);
		const close: Record<string, string> = { "«": "»", "»": "«" };
		if (
			out.length > 1 &&
			out.endsWith(close[first] ?? first) &&
			`"'«»`.includes(first) &&
			!`"'`.includes(src.trim().slice(0, 1))
		) {
			out = out.slice(1, -1).trim();
		}
		if (!src.includes("\n")) {
			out = out.replaceAll(NEWLINE, "").trim();
		}
		// Batch bleed: a neighbour line's masked tags make the model wrap plain labels
		// too ("Getting Started" -> "<0>Erste Schritte</0>"). Untagged source, no tags.
		if (!/<[a-zA-Z]/u.test(src)) {
			out = out.replace(/<\/?\d+\s*\/?>/gu, "").trim();
			// "<Claude>", "<보유한>": brackets around a word in copy that has no tags.
			out = out.replace(/<(?<word>[^<>/\s][^<>]{0,40})>/gu, "$<word>");
		}
		// "*Backend* Engram": emphasis the source never asked for shows as literal stars.
		if (!src.includes("*")) {
			out = out.replace(/\*(?<word>[^*\s](?:[^*]*[^*\s])?)\*/gu, "$<word>");
		}
		if (!/[.!?…:。]\s*$/u.test(src)) {
			out = out.replace(/[.。．]$/u, "");
		}
		if (spaceless) {
			out = out.replace(CJK_STOP, "$<stop>");
		}
		out = out
			.replace(/[ \t]*⏎[ \t]*/gu, "\n")
			.replace(/[ \t]{2,}/gu, " ")
			.trim();
		// Edge spaces join this string to its neighbours (" conflicts need resolution"
		// after a count); the model trims them. Spaceless scripts need none.
		return spaceless ? out : `${lead(src)}${out}${trail(src)}`;
	}

	// Names of the checks `out` fails as a translation of `src`. The translator and
	// the catalog gate both call this. `old`, the entry `out` would replace, may only
	// add a check, never waive one: the gate has no `old`, so a waiver here would let
	// the translator write what the gate then rejects.
	function problems(src: string, out: string, code: T, old?: string): string[] {
		const { formal, script, spaceless } = specs[code];
		const failed: Record<string, boolean> = {
			empty: out.trim().length === 0,
			placeholders: placeholders(out).join() !== placeholders(src).join(),
			tags: tags(out) !== tags(src),
			// A numbered token left after unmasking was invented by the model.
			stray:
				(NUMBERED.test(out) && !NUMBERED.test(src)) ||
				// Or it copied a prompt's `English -> answer` format.
				(/->|=>/u.test(out) && !/->|=>/u.test(src)),
			// A plural sample ("2 of {indexed} notes") came back as "{indexed} of {indexed}".
			numbers: !numbers(src, true).every((n) => numbers(out).includes(n)),
			newlines: out.split("\n").length !== src.split("\n").length,
			literal: !(src.match(LITERAL) ?? []).every((lit) => out.includes(lit)),
			brand: !brands.every((b) => !hasBrand(src, b) || hasBrand(out, b, true)),
			// Both ways: a label keeps its emoji, and a sentence does not gain one.
			symbols: symbols(src) !== symbols(out),
			edges: !spaceless && (lead(out) !== lead(src) || trail(out) !== trail(src)),
			length: out.length > 3 * src.length + 15,
			register: Boolean(formal?.test(out)),
			// Only sentences: "ID:", "A → Z" or a bare "{status}: {message}" may stay Latin.
			script: Boolean(script && words(prose(src)) > 3 && !script.test(out)),
			// English echoed back. Only a language's loanwords may stay ("Status" in
			// German), and never over a real translation.
			untranslated:
				out === src &&
				!isBrandOnly(src) &&
				(!isLoanword(code, src, prose(src)) || (old !== undefined && old !== src)),
		};
		return Object.keys(failed).filter((name) => failed[name]);
	}

	function isValid(src: string, out: string, code: T, old?: string): boolean {
		return problems(src, out, code, old).length === 0;
	}

	// Why `value` cannot stand as the catalog entry for `entry`, or [] if it can.
	function entryProblems(entry: Entry, value: Catalog[string], code: T): string[] {
		if (!entry.plural) {
			return typeof value === "string" ? problems(entry.key, value, code) : ["shape"];
		}
		const want = pluralCategories(code);
		// A single-form language (ja, ko, zh) may store its plural as a plain string.
		const forms =
			typeof value === "string" ? (want.length === 1 ? { other: value } : undefined) : value;
		if (!(forms && want.every((c) => typeof forms[c] === "string"))) {
			return ["shape"];
		}
		return [
			...new Set(
				want.flatMap((c) => {
					const form = forms[c] ?? "";
					// Only a `one` that means exactly 1 may spell the number out.
					const dropped =
						entry.key.includes("{count}") &&
						!form.includes("{count}") &&
						!(c === "one" && exactOne(code));
					return [
						...(dropped ? ["count"] : []),
						...problems(formSource(entry.key, form), form, code),
					];
				}),
			),
		];
	}

	// Entries already in a catalog that fail a check as it stands today. The script
	// retranslates them, so a new rule heals old entries on the next run.
	function invalidKeys(entries: readonly Entry[], catalog: Catalog, code: T): string[] {
		return entries
			.filter((e) => e.key in catalog && entryProblems(e, catalog[e.key] ?? "", code).length > 0)
			.map((e) => e.key);
	}

	// The gate every committed catalog must pass (each repo's catalog test calls it).
	// A key the translator gave up on (in `state.failed`) may be missing or invalid:
	// it is tracked there, and the bot fails once it is stuck for too long.
	function catalogProblems(
		entries: readonly Entry[],
		catalog: Catalog,
		code: T,
		state: LocaleState | undefined,
	): string[] {
		const failed = state?.failed ?? {};
		const used = new Set(entries.map((e) => e.key));
		const out: string[] = [];
		const pins = pinned[code] ?? [];
		for (const e of entries) {
			// A pinned key is never retranslated, so its failure is never excused.
			if (e.key in failed && !pins.includes(e.key)) {
				continue;
			}
			const value = catalog[e.key];
			if (value === undefined) {
				out.push(`${code}: missing ${JSON.stringify(e.key)}`);
				continue;
			}
			const found = entryProblems(e, value, code);
			if (found.length > 0) {
				out.push(`${code}: ${found.join(", ")} in ${JSON.stringify(e.key)}`);
			}
		}
		for (const key of Object.keys(catalog)) {
			if (!used.has(key)) {
				out.push(`${code}: orphan ${JSON.stringify(key)}`);
			}
		}
		return out;
	}

	// The model translates names that are words ({used} -> {digunakan}, <strong> ->
	// <fuerte>, Starter -> 入门版); numbered tokens survive. Placeholders, tags and
	// brands share one index: `{0}`, `<1>…</1>`, `<2/>`. `names[i]` is the original
	// placeholder or brand, or the original opening/self-closing tag with attributes.
	function mask(src: string): { masked: string; names: string[] } {
		const names: string[] = [];
		const seen: string[] = [];
		const indexOf = (key: string, original: string): number => {
			const known = seen.indexOf(key);
			if (known !== -1) {
				return known;
			}
			seen.push(key);
			names.push(original);
			return names.length - 1;
		};
		let masked = "";
		let at = 0;
		for (const m of src.matchAll(MASKABLE)) {
			const g = m.groups ?? {};
			const start = m.index ?? 0;
			masked += src.slice(at, start);
			at = start + m[0].length;
			if (g.brand !== undefined) {
				masked += `${g.pre ?? ""}{${indexOf(g.brand, g.brand)}}`;
			} else if (g.name === undefined) {
				masked += `{${indexOf(m[0], m[0])}}`;
			} else {
				const i = indexOf(`<${g.name}>`, g.close ? `<${g.name}>` : m[0]);
				masked += g.close ? `</${i}>` : g.self ? `<${i}/>` : `<${i}>`;
			}
		}
		masked += src.slice(at);
		return { masked, names };
	}

	function unmask(out: string, names: readonly string[]): string {
		const tagName = (i: number): string =>
			/^<(?<n>[a-zA-Z][\w-]*)/u.exec(names[i] ?? "")?.groups?.n ?? "";
		return out
			.replace(/\{(?<i>\d+)\}/gu, (token, i: string) => names[Number(i)] ?? token)
			.replace(/<\/(?<i>\d+)>/gu, (token, i: string) =>
				names[Number(i)] ? `</${tagName(Number(i))}>` : token,
			)
			.replace(/<(?<i>\d+)\s*\/?>/gu, (token, i: string) => names[Number(i)] ?? token);
	}

	// Everything that shapes an answer, for the state fingerprint. The probes run
	// buildPrompt, so a change to its wording or rules counts too.
	function fingerprintSource(code: T): string {
		const probes = ["Save", "{count} notes", "Open <b>Obsidian</b>", "a\nb"];
		return JSON.stringify([
			specs[code],
			[...brands],
			[...glossary],
			probes.map((p) => buildPrompt(code, { Vault: "Vault" }, batchText([mask(p).masked]), true)),
			String(specs[code].formal ?? ""),
			String(specs[code].script ?? ""),
		]);
	}

	return {
		buildPrompt,
		descriptions,
		pinned,
		catalogProblems,
		cleanOutput,
		entryProblems,
		fingerprintSource,
		glossary,
		invalidKeys,
		isBrandOnly,
		isValid,
		mask,
		problems,
		specs,
		unmask,
	};
}

type Translator<T extends string> = ReturnType<typeof translator<T>>;

// Headline copy is lines joined by <br />, often with a line wholly wrapped in one
// tag ("Yours to own.<br /><primary>Yours to leave.</primary>"). gemma reshuffles
// such tags no matter how they are masked, so the fallback translates each line's
// plain text and rebuilds the markup. A tag mid-line needs the whole sentence: null.
function richLines(
	src: string,
): { inner: string[]; join: (parts: readonly string[]) => string } | null {
	if (!/<[a-z]/u.test(src)) {
		return null;
	}
	const lines = src.split("<br />");
	const wraps = lines.map((l) => /^<(?<n>[a-z]+)>(?<body>[^<]*)<\/\k<n>>$/u.exec(l));
	const inner = lines.map((l, i) => wraps[i]?.groups?.body ?? l);
	if (inner.some((t) => /[<>]/u.test(t))) {
		return null;
	}
	return {
		inner,
		join: (parts) =>
			parts
				.map((p, i) => {
					const n = wraps[i]?.groups?.n;
					return n ? `<${n}>${p}</${n}>` : p;
				})
				.join("<br />"),
	};
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
function pluralSamples(code: string): { category: Intl.LDMLPluralRule; sample: string }[] {
	const rules = new Intl.PluralRules(code);
	return pluralCategories(code).map((category) => {
		// `one` gets 1 where it means only 1. Where it also covers 21 (ru) it gets 21,
		// so the model keeps the digit instead of writing "Одна". Anything else
		// starts at 2, so "1 days" never reaches the model.
		const candidates = category === "one" && exactOne(code) ? [1] : [];
		for (let n = 2; n <= 200; n++) {
			candidates.push(n);
		}
		// `many` in pt/fr/es/it is for a million and up; `one` in pt is 0 and 1.
		candidates.push(1_000_000, 1, 0);
		const n = candidates.find((c) => rules.select(c) === category);
		return { category, sample: n === undefined ? "1.5" : String(n) };
	});
}

function fromSample(out: string, sample: string): string | null {
	// The leading group stands in for a lookbehind (not a digit, comma or dot).
	// "1.5" may come back as "1,5" or "1. 5", and 1000000 as "1.000.000" or "1 000 000".
	const digits = sample.includes(".")
		? sample.replace(".", "\\s?[.,]\\s?")
		: sample.replace(/\B(?=(?:\d{3})+$)/gu, "[.,\\u00a0\\u202f ]?");
	const pattern = new RegExp(`(^|[^\\d.,])${digits}(?![\\d]|[.,]\\d)`, "gu");
	const hits = out.match(pattern) ?? [];
	return hits.length === 1 ? out.replace(pattern, "$1{count}") : null;
}

// Problems with the source's own strings, independent of any locale.
function sourceProblems(entries: readonly Entry[]): string[] {
	return entries
		.filter((e) => e.plural && !e.key.includes("{count}"))
		.map((e) => `plural without {count}, so no form can be sampled: ${JSON.stringify(e.key)}`);
}

// A state.json entry as read from disk: the current shape, or the numbered-version
// shape the repos used before the fingerprint (failed as a key list).
interface StoredState {
	translator?: string;
	version?: number;
	failed?: string[] | Record<string, string>;
	one?: Record<string, string>;
	glossary?: Record<string, string>;
	descriptions?: Record<string, string>;
}

function upgradeState(
	s: StoredState | undefined,
	fingerprint: string,
	legacyVersion: number | undefined,
	today: string,
): LocaleState | undefined {
	if (!s) {
		return undefined;
	}
	const failed = Array.isArray(s.failed)
		? Object.fromEntries(s.failed.map((k) => [k, today]))
		: (s.failed ?? {});
	// ponytail: one-time adoption of a numbered-version state, delete once every
	// repo's state.json carries a translator fingerprint.
	const stamp =
		s.translator ??
		(legacyVersion !== undefined && s.version === legacyVersion ? fingerprint : "legacy");
	return {
		translator: stamp,
		failed,
		one: s.one,
		glossary: s.glossary,
		descriptions: s.descriptions,
	};
}

// Plurals whose English `one` form changed since the catalog was built.
function oneChangedKeys(entries: readonly Entry[], state: LocaleState | undefined): string[] {
	return entries
		.filter((e) => e.plural?.one !== undefined && state?.one?.[e.key] !== e.plural.one)
		.map((e) => e.key);
}

function todoKeys(
	entries: readonly Entry[],
	catalog: Catalog,
	all: boolean,
	state: LocaleState | undefined,
	fingerprint: string,
): string[] {
	const stale = all || !state || state.translator !== fingerprint;
	const failed = state?.failed ?? {};
	const keys = [...new Set(entries.map((e) => e.key))];
	const oneChanged = new Set(oneChangedKeys(entries, state));
	return keys.filter((k) => stale || !(k in catalog) || k in failed || oneChanged.has(k));
}

// Strings whose description was added, edited or removed since the catalog was built.
function descriptionChangedKeys(
	entries: readonly Entry[],
	state: LocaleState | undefined,
	descriptions: Readonly<Record<string, string>>,
): string[] {
	return entries
		.filter((e) => state?.descriptions?.[e.key] !== descriptions[e.key])
		.map((e) => e.key);
}

// Sentences that use a glossary term whose translation changed since the catalog
// was built: they were translated with the old term.
function glossaryStale(
	entries: readonly Entry[],
	before: Record<string, string> | undefined,
	after: Record<string, string>,
): string[] {
	if (!before) {
		return [];
	}
	const changed = Object.keys(after).filter(
		(k) => before[k] !== undefined && before[k] !== after[k],
	);
	if (changed.length === 0) {
		return [];
	}
	const term = new RegExp(
		`(?:^|[^\\p{L}])(?:${changed.map((k) => escapeRegExp(k.replace(SYMBOL, "").trim())).join("|")})(?![\\p{L}])`,
		"iu",
	);
	return entries.filter((e) => !(e.key in after) && term.test(e.key)).map((e) => e.key);
}

// `failed`: keys whose catalog entry is still missing or invalid after the run.
function nextLocaleState(
	failed: readonly string[],
	entries: readonly Entry[],
	prev: LocaleState | undefined,
	fingerprint: string,
	glossary: Record<string, string>,
	today: string,
	descriptions: Readonly<Record<string, string>> = {},
): LocaleState {
	const since: Record<string, string> = {};
	for (const k of [...failed].sort()) {
		since[k] = prev?.failed[k] ?? today;
	}
	const one: Record<string, string> = {};
	for (const { key, plural } of entries) {
		if (plural?.one !== undefined && !(key in since)) {
			one[key] = plural.one;
		}
	}
	const described: Record<string, string> = {};
	for (const { key } of entries) {
		const note = descriptions[key];
		if (note !== undefined && !(key in since)) {
			described[key] = note;
		}
	}
	const state: LocaleState = { translator: fingerprint, failed: since, one, glossary };
	// Omitted when empty, so a repo without descriptions keeps its state file as is.
	return Object.keys(described).length > 0 ? { ...state, descriptions: described } : state;
}

// Failed keys older than `days`: the model cannot translate them, so a person must
// reword the source or the prompt.
function stuckKeys(state: LocaleState | undefined, today: string, days: number): string[] {
	const limit = Date.parse(today) - days * 86_400_000;
	return Object.entries(state?.failed ?? {})
		.filter(([, since]) => Date.parse(since) < limit)
		.map(([key]) => key);
}

// Source order, fresh over old; a key no longer in the source (an edited or
// removed English string) is dropped, which keeps the catalogs free of orphans.
function mergeCatalog(entries: readonly Entry[], old: Catalog, fresh: Catalog): Catalog {
	const merged: Catalog = {};
	for (const { key } of entries) {
		const value = fresh[key] ?? old[key];
		if (value !== undefined) {
			merged[key] = value;
		}
	}
	return merged;
}

// A non-2xx answer from Ollama. 5xx is transient (busy, loading); 4xx is not.
class HttpError extends Error {
	readonly status: number;

	constructor(status: number, message: string) {
		super(message);
		this.status = status;
	}
}

// FastRaid's Ollama is shared: another model loading can stall one request for
// minutes. A timeout, a dropped connection or a 5xx is retried after each delay
// (ms); a 4xx (wrong model name) fails at once.
async function withRetry<T>(
	fn: () => Promise<T>,
	delays: readonly number[],
	sleep: (ms: number) => Promise<void>,
	warn: (message: string) => void = () => undefined,
): Promise<T> {
	for (const delay of delays) {
		try {
			return await fn();
		} catch (error) {
			if (error instanceof HttpError && error.status < 500) {
				throw error;
			}
			warn(`Ollama request failed (${String(error)}); retrying in ${delay / 1000}s`);
			await sleep(delay);
		}
	}
	return fn();
}

export type { Catalog, Entry, LocaleState, PluralForms, Profile, Spec, StoredState, Translator };
export {
	batchText,
	coreHeaderOk,
	descriptionChangedKeys,
	exactOne,
	formSource,
	fromSample,
	glossaryStale,
	HttpError,
	hash,
	mergeCatalog,
	nextLocaleState,
	oneChangedKeys,
	parseBatch,
	pluralCategories,
	pluralSamples,
	richLines,
	sourceProblems,
	stuckKeys,
	todoKeys,
	translator,
	upgradeState,
	withRetry,
};

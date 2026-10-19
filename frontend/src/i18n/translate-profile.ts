// The web app's translategemma profile: languages, register, glossary and brand
// names. The pipeline itself is the shared core in ./core (see core/README.md).
import { type Profile, type Spec, translator } from "./core/core";
import type { Locale } from "./locales";

type Target = Exclude<Locale, "en">;

const HAN = /\p{Script=Han}/u;

const SPECS: Record<Target, Spec> = {
	cs: {
		name: "Czech",
		tone: "Address the user formally (vy, váš), never ty.",
		formal:
			/(?<![\p{L}])(?:tvůj|tvoje|tvého|tvému|tvém|tvým|tvá|tvé|tvou|tvoji|tvých|tvými|tebe|tobě|tebou)(?![\p{L}])/iu,
	},
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
	id: {
		name: "Indonesian",
		tone: "Address the user as Anda, never kamu.",
		formal: /(?<![\p{L}])(?:kamu|kau|engkau|dikau)(?![\p{L}])/iu,
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
		spaceless: true,
	},
	ko: { name: "Korean", tone: "Use polite, concise UI Korean.", script: /\p{Script=Hangul}/u },
	ms: { name: "Malay", tone: "Address the user as anda." },
	pl: {
		name: "Polish",
		tone: "Address the user informally (ty, twój), never Pan or Pani.",
		// \b is ASCII-only even with u, so letter lookarounds (as ru/tr) and every case form.
		formal:
			/(?<![\p{L}])(?:pan|pani|pana|panu|panem|panie|panią|państwo|państwa|państwu|państwem|pańsk\p{L}*)(?![\p{L}])/iu,
	},
	"pt-BR": { name: "Brazilian Portuguese", tone: "Address the user as você." },
	ru: {
		name: "Russian",
		tone: "Address the user formally (вы, ваш), never ты.",
		formal: /(?<![\p{L}])(?:ты|твой|твоя|твоё|твои|тебя|тебе)(?![\p{L}])/iu,
		script: /\p{Script=Cyrillic}/u,
	},
	tr: {
		name: "Turkish",
		// Naming the pronouns made gemma paste "{siz}" in as a placeholder (2026-10-16).
		tone: "Use polite, concise UI Turkish.",
		formal: /(?<![\p{L}])(?:sen|senin|sana|seni|sende|senden|seninle)(?![\p{L}])/iu,
	},
	uk: {
		name: "Ukrainian",
		tone: "Address the user formally (ви, ваш), never ти.",
		formal: /(?<![\p{L}])(?:ти|твій|твоя|твоє|твої|твого|твоїй|тебе|тобі|тобою)(?![\p{L}])/iu,
		script: /\p{Script=Cyrillic}/u,
	},
	vi: { name: "Vietnamese", tone: "Address the user as bạn." },
	"zh-CN": {
		name: "Simplified Chinese",
		tone: "Use concise Simplified Chinese UI wording.",
		script: HAN,
		spaceless: true,
	},
	"zh-TW": {
		name: "Traditional Chinese",
		tone: "Use concise Traditional Chinese (Taiwan) UI wording.",
		script: HAN,
		spaceless: true,
	},
};

// Terms held fixed across every batch so "vault" is not three different words.
const GLOSSARY_KEYS = [
	"Note",
	"Vault",
	"Vaults",
	"Sync",
	"Attachments",
	"Folder",
	"Tags",
	"Backlinks",
	"Properties",
	"Wikilink",
	"Connections",
	"Settings",
	"Search",
	"Manage your profile, password, and account.",
];
// Hand overrides, each copied from Obsidian's own translation of the same
// string: the model's answer meant something else ("Strikethrough" as underline,
// "Reading" as loading) or differed from the word Obsidian users already know.
const PINNED: Partial<Record<Target, readonly string[]>> = {
	cs: ["Backlinks", "Tags", "Vault", "Vaults", "Wikilink"],
	de: ["Reading view"],
	it: ["Outline", "Strikethrough"],
	ja: ["Dark", "Light", "Outline", "Reading", "Reading view"],
	id: [
		"Dark",
		"Light",
		"Outline",
		"Reading",
		"Reading view",
		"Strikethrough",
		"Math",
		"Frontmatter",
		"frontmatter",
	],
	ms: ["Idea", "Outline", "Reading", "Reading view", "Strikethrough"],
	pl: [
		"Dark",
		"Light",
		"Outline",
		"Reading",
		"Reading view",
		"Strikethrough",
		"Math",
		"Frontmatter",
		"frontmatter",
	],
	"pt-BR": ["Reading"],
	ru: ["Outline"],
	tr: ["Dark", "Light", "Outline", "Reading", "Reading view", "Strikethrough", "Math"],
	vi: ["Light", "Outline", "Reading", "Reading view", "Strikethrough"],
	"zh-CN": ["Dark", "Outline", "Reading"],
	"zh-TW": ["Math", "Redo edit"],
};

// What a short label means where it shows, for the translator (see Profile).
// Add one when a label's words allow two senses; editing one redoes it. Check
// the result: with translategemma a note fixes some labels and breaks others
// (on 2026-10-12 it turned ms "Light" into "lightweight"), so keep only notes
// whose output you reviewed.
const DESCRIPTIONS: Readonly<Record<string, string>> = {
	// cs read {folder} as a vault ("ve skladu", 2026-10-18).
	"Notes in {folder}": "Heading over the notes inside a folder; {folder} is the folder's name.",
	// ja joined the items with 、 and dropped the separators (2026-10-18).
	"3,000 notes · 20 AI searches a day · 1 vault":
		"Free plan summary: three short items. Keep each ' · ' separator between them exactly as written.",
	Reading: "Note view mode that shows the rendered note, read-only, like Obsidian's Reading view.",
	"Reading view": "Note view mode that shows the rendered note, read-only, as named in Obsidian.",
	Idea: "Feedback category: suggest a feature.",
	// uk gave its word for Weekly to both (2026-10-19), so the billing toggle
	// read "Weekly | Annually".
	Monthly: "Billing period: charged once a month. Not weekly.",
	monthly: "Billing period, lower case: charged once a month. Not weekly.",
	// The Revoke confirm dialog's destructive button. Its own key because the
	// generic "Revoke" matched Cancel in ko, ms and ru (2026-10-14).
	"Revoke access":
		"Destructive button that removes an app's access; must differ from Cancel, which sits next to it.",
	// Permission column headers in the vault access table. Without a note ja,
	// zh and ru rendered "Write" as the verb "compose" (書く, 撰写, Написать).
	Read: "Permission column header in a vault access table: the connection may read notes. A noun, not a verb.",
	Write:
		"Permission column header in a vault access table, next to the 'Read' column: the connection may change notes. Names the permission (a noun like 'write access'), never a command and never a Save button.",
	// A button on each connection. Without a note de and ja read it as a noun,
	// "access for editing" (Bearbeitungszugriff, 編集権限).
	"Edit access":
		"Button that opens a dialog to change which vaults a connection can reach. An action (a verb phrase, like 'Change access'), not a noun.",
	"Edit access for {name}":
		"Title of the dialog where the user changes which vaults the named connection can reach. An action (a verb phrase, like 'Change access for {name}'), not a noun.",
	// Meaning check, 2026-10-16: "device" came back as an office (pl) and the label
	// as a full sentence (ja). Other misread sources were reworded instead.
	"Your plan resumes on {date}":
		"Billing banner: a subscription that was set to cancel becomes active again on this date.",
	"the device on {os} that syncs your '{vault}' vault (last active {since})":
		"Names an already-connected device (computer or phone) by the vault it syncs. A noun phrase, not a sentence.",
	"the device on {os} that syncs your '{vault}' vault":
		"Names an already-connected device (computer or phone) by the vault it syncs. A noun phrase, not a sentence.",
	"the device that syncs your '{vault}' vault (last active {since})":
		"Names an already-connected device (computer or phone) by the vault it syncs. A noun phrase, not a sentence.",
	"the device that syncs your '{vault}' vault":
		"Names an already-connected device (computer or phone) by the vault it syncs. A noun phrase, not a sentence.",
	// Email strings (priv/i18n/email). zh/ja greeted with a casual "嗨" while the
	// body used the polite form.
	"Hi,":
		"Email greeting with no name. Warm, at the same politeness level as the rest of the email.",
	"Hi {name},":
		"Email greeting by first name. Warm, at the same politeness level as the rest of the email.",
};

// Product and plan names: never translated. Plan names match invoices and Paddle
// checkout (its catalog is English); "Free" describes the price, so it is translated.
const BRANDS = [
	"Engram",
	"Obsidian",
	"MCP",
	"Paddle",
	"Clerk",
	"GitHub",
	"Claude",
	"ChatGPT",
	// A named spec, not a description of one.
	"Open Knowledge Format",
	"Starter",
	"Pro",
];

const profile: Profile<Target> = {
	subject:
		"the user interface of Engram, a notes app that syncs an Obsidian vault and exposes it to AI assistants",
	specs: SPECS,
	brands: BRANDS,
	glossary: GLOSSARY_KEYS,
	pinned: PINNED,
	descriptions: DESCRIPTIONS,
};

const tr = translator(profile);

// TRANSLATOR_VERSION before the fingerprint replaced it (core upgradeState).
const LEGACY_VERSION = 2;

export type { Target };
export { LEGACY_VERSION, profile, tr };

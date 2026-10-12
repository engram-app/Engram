// The web app's translategemma profile: languages, register, glossary and brand
// names. The pipeline itself is the shared core in ./core (see core/README.md).
import { type Profile, type Spec, translator } from "./core/core";
import type { Locale } from "./locales";

type Target = Exclude<Locale, "en">;

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
		spaceless: true,
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
};

const tr = translator(profile);

// TRANSLATOR_VERSION before the fingerprint replaced it (core upgradeState).
const LEGACY_VERSION = 2;

export type { Target };
export { LEGACY_VERSION, profile, tr };

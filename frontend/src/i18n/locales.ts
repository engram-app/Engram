const localesArray = [
	"en",
	"cs",
	"de",
	"es",
	"fr",
	"id",
	"it",
	"ja",
	"ko",
	"ms",
	"pl",
	"pt-BR",
	"ru",
	"tr",
	"uk",
	"vi",
	"zh-CN",
	"zh-TW",
] as const;

type Locale = (typeof localesArray)[number];

const BY_LOWER = new Map<string, Locale>(localesArray.map((l) => [l.toLowerCase(), l]));
const TRADITIONAL = /^zh-(?<region>tw|hk|mo|hant)/u;

const localeNames: Record<Locale, string> = {
	en: "English",
	cs: "Čeština",
	de: "Deutsch",
	es: "Español",
	fr: "Français",
	id: "Bahasa Indonesia",
	it: "Italiano",
	ja: "日本語",
	ko: "한국어",
	ms: "Bahasa Melayu",
	pl: "Polski",
	"pt-BR": "Português (Brasil)",
	ru: "Русский",
	tr: "Türkçe",
	uk: "Українська",
	vi: "Tiếng Việt",
	"zh-CN": "简体中文",
	"zh-TW": "繁體中文",
};

function matchLocale(tag: string): Locale | null {
	const lower = tag.toLowerCase();
	const exact = BY_LOWER.get(lower);
	if (exact) {
		return exact;
	}
	if (TRADITIONAL.test(lower)) {
		return "zh-TW";
	}
	const base = lower.split("-")[0] ?? "";
	if (base === "zh") {
		return "zh-CN";
	}
	if (base === "pt") {
		return "pt-BR";
	}
	// Slovak readers get Czech, the closest language we ship.
	if (base === "sk") {
		return "cs";
	}
	return BY_LOWER.get(base) ?? null;
}

function resolveLocale(languages: readonly string[]): Locale {
	for (const tag of languages) {
		const match = matchLocale(tag);
		if (match) {
			return match;
		}
	}
	return "en";
}

export const LOCALES = localesArray;
export type { Locale };
export const LOCALE_NAMES = localeNames;
export { matchLocale, resolveLocale };

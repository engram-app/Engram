import type { deDE } from "@clerk/localizations";
import type { Locale } from "./locales";

type ClerkLocalization = typeof deDE;
type ClerkLocalizationLoaders = Partial<Record<Locale, () => Promise<ClerkLocalization>>>;

// Paddle.js `settings.locale` codes match ours except Simplified Chinese.
const PADDLE_CODES: Partial<Record<Locale, string>> = { "zh-CN": "zh-Hans" };

function paddleLocale(locale: Locale): string {
	return PADDLE_CODES[locale] ?? locale;
}

// Literal specifiers: Vite emits one lazy chunk per language. `en` is Clerk's default.
const clerkLocalizationLoaders: ClerkLocalizationLoaders = {
	de: async () => (await import("@clerk/localizations/de-DE")).deDE,
	es: async () => (await import("@clerk/localizations/es-ES")).esES,
	fr: async () => (await import("@clerk/localizations/fr-FR")).frFR,
	it: async () => (await import("@clerk/localizations/it-IT")).itIT,
	ja: async () => (await import("@clerk/localizations/ja-JP")).jaJP,
	ko: async () => (await import("@clerk/localizations/ko-KR")).koKR,
	"pt-BR": async () => (await import("@clerk/localizations/pt-BR")).ptBR,
	ru: async () => (await import("@clerk/localizations/ru-RU")).ruRU,
	"zh-CN": async () => (await import("@clerk/localizations/zh-CN")).zhCN,
	"zh-TW": async () => (await import("@clerk/localizations/zh-TW")).zhTW,
};

export type { ClerkLocalization };
export { clerkLocalizationLoaders, paddleLocale };

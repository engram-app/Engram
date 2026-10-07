import type { deDE } from "@clerk/localizations";
import type { Locale } from "./locales";

type ClerkLocalization = typeof deDE;
type ClerkLocalizationLoaders = Partial<
	Record<Locale, () => Promise<ClerkLocalization | undefined>>
>;

// Paddle.js `settings.locale` codes match ours except Simplified Chinese.
const PADDLE_CODES: Partial<Record<Locale, string>> = { "zh-CN": "zh-Hans" };

function paddleLocale(locale: Locale): string {
	return PADDLE_CODES[locale] ?? locale;
}

// The module may be undefined: vite:preloadError's preventDefault() makes the
// preload resolve nothing, and reading the key then would throw a TypeError.
function localizationLoader<Key extends string>(
	importModule: () => Promise<Record<Key, ClerkLocalization> | undefined>,
	key: Key,
): () => Promise<ClerkLocalization | undefined> {
	return async () => (await importModule())?.[key];
}

// Literal specifiers: Vite emits one lazy chunk per language. `en` is Clerk's default.
const clerkLocalizationLoaders: ClerkLocalizationLoaders = {
	de: localizationLoader(() => import("@clerk/localizations/de-DE"), "deDE"),
	es: localizationLoader(() => import("@clerk/localizations/es-ES"), "esES"),
	fr: localizationLoader(() => import("@clerk/localizations/fr-FR"), "frFR"),
	it: localizationLoader(() => import("@clerk/localizations/it-IT"), "itIT"),
	ja: localizationLoader(() => import("@clerk/localizations/ja-JP"), "jaJP"),
	ko: localizationLoader(() => import("@clerk/localizations/ko-KR"), "koKR"),
	"pt-BR": localizationLoader(() => import("@clerk/localizations/pt-BR"), "ptBR"),
	ru: localizationLoader(() => import("@clerk/localizations/ru-RU"), "ruRU"),
	"zh-CN": localizationLoader(() => import("@clerk/localizations/zh-CN"), "zhCN"),
	"zh-TW": localizationLoader(() => import("@clerk/localizations/zh-TW"), "zhTW"),
};

export type { ClerkLocalization };
export { clerkLocalizationLoaders, localizationLoader, paddleLocale };

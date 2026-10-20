import { whenLoaded } from "@/lib/when-loaded";
import { readStorage, writeStorage } from "./browser-language";
import type { CatalogLoaders } from "./locale-provider";
import { LOCALE_NAMES, type Locale, matchLocale } from "./locales";
import { type Catalog, type Translate, translate } from "./translate";

const DECLINED_KEY = "engram:translation-prompt-declined";

interface Current {
	locale: Locale;
	setLocale: (next: Locale) => void;
	loaders: CatalogLoaders;
}

/** The target locale's catalog, or none (English) when it has no loader or
 *  fails to load: never the current locale's. */
async function catalogFor(locale: Locale, loaders: CatalogLoaders): Promise<Catalog> {
	const load = loaders[locale];
	if (!load) {
		return {};
	}
	try {
		return (await whenLoaded(load())).default;
	} catch {
		// Offline or a stale deploy: offer it in English rather than not at all.
		return {};
	}
}

/** The browser is translating the page into `target`. If the app ships that
 *  language, offer the real translation, written entirely in the target
 *  language (that is the language the reader chose), marked translate="no" so
 *  the translator leaves it alone. The name is LOCALE_NAMES', as in the
 *  language picker. Closing the toast, "Not now", or letting it time out
 *  declines that locale for good on this device: the user has seen the offer,
 *  and a translator they keep using would otherwise re-prompt every session. */
async function offerLocaleSwitch(target: string, { locale, setLocale, loaders }: Current) {
	const match = matchLocale(target);
	const declined = readStorage("localStorage", DECLINED_KEY)?.split(",") ?? [];
	if (!match || match === locale || declined.includes(match)) {
		return;
	}
	const decline = () => writeStorage("localStorage", DECLINED_KEY, [...declined, match].join(","));
	const catalog = await catalogFor(match, loaders);
	const t: Translate = (en, vars) => translate(catalog, en, vars);
	const inTarget = (text: string) => (
		<span lang={match} translate="no">
			{text}
		</span>
	);
	// notify pulls in sonner, which stays out of the eager bundle (main.tsx).
	const { notify } = await whenLoaded(import("@/lib/notify"));
	notify(inTarget(t("Show Engram in {language}?", { language: LOCALE_NAMES[match] })), {
		action: { label: inTarget(t("Switch language")), onClick: () => setLocale(match) },
		cancel: { label: inTarget(t("Not now")), onClick: decline },
		onDismiss: decline,
		onAutoClose: decline,
	});
}

export { offerLocaleSwitch };

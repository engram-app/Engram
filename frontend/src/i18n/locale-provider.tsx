import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useEffect,
	useMemo,
	useState,
} from "react";
import { captureError } from "../sentry";
import { LOCALES, type Locale, resolveLocale } from "./locales";
import { getStoredLocale, setStoredLocale } from "./storage";
import { type Catalog, type PluralForms, translate, translatePlural, type Vars } from "./translate";

type CatalogLoaders = Partial<Record<Locale, () => Promise<{ default: Catalog }>>>;

// Vite splits each catalog into its own lazy chunk; `en` has no file.
const globbed = import.meta.glob<{ default: Catalog }>("./locale/*.ts");
const defaultLoaders: CatalogLoaders = {};
for (const locale of LOCALES) {
	const load = globbed[`./locale/${locale}.ts`];
	if (load) {
		defaultLoaders[locale] = load;
	}
}

type PluralEn = PluralForms & { other: string };

interface LocaleContextValue {
	locale: Locale;
	setLocale: (next: Locale) => void;
	t: (en: string, vars?: Vars) => string;
	tn: (en: PluralEn, count: number, vars?: Vars) => string;
}

// Un-wrapped trees (and the tests that predate i18n) get English, not a throw:
// an untranslated string is the designed fallback, not an error.
const ENGLISH: LocaleContextValue = {
	locale: "en",
	setLocale: () => undefined,
	t: (en, vars) => translate({}, en, vars),
	tn: (en, count, vars) => translatePlural({}, "en", en, count, vars),
};

const NO_CATALOG: Catalog = {};

const LocaleContext = createContext<LocaleContextValue>(ENGLISH);

export function LocaleProvider({
	children,
	loaders = defaultLoaders,
}: {
	children: ReactNode;
	loaders?: CatalogLoaders;
}) {
	const [locale, setLocaleState] = useState<Locale>(
		() => getStoredLocale() ?? resolveLocale(navigator.languages),
	);
	// Tagged with its locale so a catalog for a locale we left is never shown.
	const [loaded, setLoaded] = useState<{ locale: Locale; catalog: Catalog }>();
	const catalog = loaded?.locale === locale ? loaded.catalog : NO_CATALOG;

	useEffect(() => {
		document.documentElement.lang = locale;
		const load = loaders[locale];
		if (!load) {
			return;
		}
		let current = true;
		load()
			.then((mod) => {
				if (current) {
					setLoaded({ locale, catalog: mod.default });
				}
			})
			.catch(async (error: unknown) => {
				// Stale deploy or offline: keep the English fallback, but report it.
				await captureError(error);
			});
		return () => {
			current = false;
		};
	}, [locale, loaders]);

	const setLocale = useCallback((next: Locale) => {
		setStoredLocale(next);
		setLocaleState(next);
	}, []);

	const value = useMemo<LocaleContextValue>(
		() => ({
			locale,
			setLocale,
			t: (en, vars) => translate(catalog, en, vars),
			tn: (en, count, vars) => translatePlural(catalog, locale, en, count, vars),
		}),
		[locale, setLocale, catalog],
	);
	return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
}

export function useT(): LocaleContextValue {
	return useContext(LocaleContext);
}

export type { CatalogLoaders };

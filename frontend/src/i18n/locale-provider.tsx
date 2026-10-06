import {
	createContext,
	type ReactNode,
	useCallback,
	useContext,
	useEffect,
	useLayoutEffect,
	useMemo,
	useRef,
	useState,
} from "react";
import { captureError } from "../sentry";
import { LOCALES, type Locale, resolveLocale } from "./locales";
import { getStoredLocale, setStoredLocale } from "./storage";
import { type Catalog, type PluralForms, translate, translatePlural, type Vars } from "./translate";

type CatalogLoaders = Partial<Record<Locale, () => Promise<{ default: Catalog } | undefined>>>;
// ^ undefined: vite:preloadError's preventDefault() makes the preload resolve nothing.

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
	// What is actually on screen: the locale of the catalog being shown (lags `locale`
	// while a new one loads; "en" before any loads).
	// Third parties (Clerk, Paddle) follow this, not the selected `locale`.
	renderedLocale: Locale;
	setLocale: (next: Locale) => void;
	t: (en: string, vars?: Vars) => string;
	tn: (en: PluralEn, count: number, vars?: Vars) => string;
}

// Un-wrapped trees (and the tests that predate i18n) get English, not a throw:
// an untranslated string is the designed fallback, not an error.
const ENGLISH: LocaleContextValue = {
	locale: "en",
	renderedLocale: "en",
	setLocale: () => undefined,
	t: (en, vars) => translate({}, en, vars),
	tn: (en, count, vars) => translatePlural({}, "en", en, count, vars),
};

const NO_CATALOG: Catalog = {};

const LocaleContext = createContext<LocaleContextValue>(ENGLISH);

function LocaleProvider({
	children,
	loaders = defaultLoaders,
}: {
	children: ReactNode;
	loaders?: CatalogLoaders;
}) {
	const [locale, setLocaleState] = useState<Locale>(
		() => getStoredLocale() ?? resolveLocale(navigator.languages),
	);
	// The last catalog that loaded, tagged with its locale. It stays on screen while
	// a newly selected language loads, so a switch never drops to English in between.
	const [loaded, setLoaded] = useState<{ locale: Locale; catalog: Catalog }>();
	const catalog = loaded?.catalog ?? NO_CATALOG;

	useEffect(() => {
		const load = loaders[locale];
		if (!load) {
			return;
		}
		let current = true;
		load()
			.then((mod) => {
				// An empty catalog is a stub, not a language: keep what is shown.
				if (current && mod && Object.keys(mod.default).length > 0) {
					setLoaded({ locale, catalog: mod.default });
				}
			})
			.catch(async (error: unknown) => {
				// Stale deploy or offline: keep the catalog on screen, but report it.
				await captureError(error);
			});
		return () => {
			current = false;
		};
	}, [locale, loaders]);

	// The language of the catalog on screen, which lags `locale` until its load lands.
	const renderedLocale = loaded?.locale ?? "en";
	// Layout effect: lang must change in the same commit as the text it describes.
	useLayoutEffect(() => {
		document.documentElement.lang = renderedLocale;
	}, [renderedLocale]);

	const setLocale = useCallback(
		(next: Locale) => {
			setStoredLocale(next);
			setLocaleState(next);
			// No loader (English): switch at once, and forget the old catalog so a later
			// switch to another language does not show it while that one loads.
			if (!loaders[next]) {
				setLoaded(undefined);
			}
		},
		[loaders],
	);

	const value = useMemo<LocaleContextValue>(
		() => ({
			locale,
			renderedLocale,
			setLocale,
			t: (en, vars) => translate(catalog, en, vars),
			tn: (en, count, vars) => translatePlural(catalog, renderedLocale, en, count, vars),
		}),
		[locale, renderedLocale, setLocale, catalog],
	);
	return <LocaleContext.Provider value={value}>{children}</LocaleContext.Provider>;
}

function useT(): LocaleContextValue {
	return useContext(LocaleContext);
}

// `t`/`tn` with identities that never change, always calling the LATEST translator.
// Use these in effect/callback dependencies and handlers: the plain `t` changes
// whenever a catalog loads or the language switches, which would re-run the effect
// (a refetch that can overwrite a just-changed setting). Do NOT call them while
// rendering: the ref catches up in a layout effect, after the render that
// switched language. Anything rendered stays on useT() (and keeps `t` in its deps).
function useStableT(): Pick<LocaleContextValue, "t" | "tn"> {
	const { t, tn } = useT();
	const latest = useRef({ t, tn });
	useLayoutEffect(() => {
		latest.current = { t, tn };
	}, [t, tn]);
	return useMemo(
		() => ({
			t: (en, vars) => latest.current.t(en, vars),
			tn: (en, count, vars) => latest.current.tn(en, count, vars),
		}),
		[],
	);
}

export type { CatalogLoaders };
export { LocaleProvider, useStableT, useT };

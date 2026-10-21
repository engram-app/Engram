import { whenAnalyticsReady } from "../analytics/client";
import { track } from "../analytics/track";
import { type Locale, matchLocale } from "./locales";

/** The user's browser languages no app locale serves, as canonical BCP-47
 *  tags, deduped. Anything that is not a language tag is dropped. */
function unsupportedLanguages(languages: readonly string[]): string[] {
	const tags = languages.flatMap((tag) => languageOf(tag) ?? []);
	return [...new Set(tags)].filter((tag) => matchLocale(tag) === null);
}

const DEMAND_KEY = "engram:language-demand-sent";

/** Once per device per distinct set: which languages this user needs that the
 *  app cannot serve. navigator.languages is the user's own configuration, so
 *  it counts demand before any translation or stored pick hides it. */
function reportLanguageDemand(languages: readonly string[] = navigator.languages): void {
	const missing = unsupportedLanguages(languages);
	const value = missing.join(",");
	if (missing.length === 0 || readStorage("localStorage", DEMAND_KEY) === value) {
		return;
	}
	whenAnalyticsReady(() => {
		track("browser_languages_unsupported", { languages: missing });
		writeStorage("localStorage", DEMAND_KEY, value);
	});
}

/** Canonical language of `tag`, or null when it is not a language tag.
 *  baseName drops -u-/-x- extensions: preferences (calendar, numbering), not
 *  a language. */
function languageOf(tag: string): string | null {
	try {
		return new Intl.Locale(tag).baseName;
	} catch {
		return null;
	}
}

// The lang we last wrote to <html>. The translation watcher compares against
// it, so our own writes (a locale switch) never read as a translation.
let ownLang: string | null = null;

/** Set <html lang>. The only writer of it: see ownLang. */
function setDocumentLang(lang: string): void {
	ownLang = lang;
	document.documentElement.lang = lang;
}

const SEEN_KEY = "engram:translation-seen";

/** Watch for browser page translation and report each target language once per
 *  session. Chrome/Google Translate add translated-ltr/-rtl to <html>'s class
 *  and set its lang to the target; other translators set lang alone. Only
 *  <html>'s own two attributes are observed (no subtree): a translation
 *  rewrites every text node, and observing those would cost on every render.
 *  `onTranslated` gets each new target, for the switch prompt. Returns stop. */
function watchTranslation(
	appLocale: () => Locale,
	onTranslated: (target: string) => void = () => undefined,
): () => void {
	const root = document.documentElement;
	const observer = new MutationObserver(() => {
		// Read the attribute now, not the mutation records: by delivery time a
		// burst of our own writes has settled on ownLang.
		const target = languageOf(root.lang);
		if (!target || ownLang === null || target === languageOf(ownLang)) {
			return;
		}
		const seen = readStorage("sessionStorage", SEEN_KEY)?.split(",") ?? [];
		if (seen.includes(target)) {
			return;
		}
		writeStorage("sessionStorage", SEEN_KEY, [...seen, target].join(","));
		whenAnalyticsReady(() =>
			track("browser_translation_detected", { to: target, app_locale: appLocale() }),
		);
		onTranslated(target);
	});
	observer.observe(root, { attributes: true, attributeFilter: ["class", "lang"] });
	return () => observer.disconnect();
}

type StorageArea = "localStorage" | "sessionStorage";

// Reaching window.localStorage itself throws in a sandboxed frame, so the
// lookup sits inside the try too.
function readStorage(area: StorageArea, key: string): string | null {
	try {
		return window[area].getItem(key);
	} catch {
		// Private mode or a sandboxed frame: behave as never sent.
		return null;
	}
}

function writeStorage(area: StorageArea, key: string, value: string): void {
	try {
		window[area].setItem(key, value);
	} catch {
		// Best-effort: the report may repeat next load.
	}
}

export {
	readStorage,
	reportLanguageDemand,
	setDocumentLang,
	unsupportedLanguages,
	watchTranslation,
	writeStorage,
};

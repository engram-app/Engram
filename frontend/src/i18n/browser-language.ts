import { whenAnalyticsReady } from "../analytics/client";
import { track } from "../analytics/track";
import { matchLocale } from "./locales";

/** The user's browser languages no app locale serves, as canonical BCP-47
 *  tags, deduped. Anything that is not a language tag is dropped. */
function unsupportedLanguages(languages: readonly string[]): string[] {
	const tags = languages.flatMap((tag) => {
		try {
			// baseName: canonical, without -u-/-x- extensions, which carry
			// preferences (calendar, numbering), not a language.
			return [new Intl.Locale(tag).baseName];
		} catch {
			// Not a language tag: nothing to count.
			return [];
		}
	});
	return [...new Set(tags)].filter((tag) => matchLocale(tag) === null);
}

const DEMAND_KEY = "engram:language-demand-sent";

/** Once per device per distinct set: which languages this user needs that the
 *  app cannot serve. navigator.languages is the user's own configuration, so
 *  it counts demand before any translation or stored pick hides it. */
function reportLanguageDemand(languages: readonly string[] = navigator.languages): void {
	const missing = unsupportedLanguages(languages);
	const value = missing.join(",");
	if (missing.length === 0 || readStorage(localStorage, DEMAND_KEY) === value) {
		return;
	}
	whenAnalyticsReady(() => {
		track("browser_languages_unsupported", { languages: missing });
		writeStorage(localStorage, DEMAND_KEY, value);
	});
}

function readStorage(storage: Storage, key: string): string | null {
	try {
		return storage.getItem(key);
	} catch {
		// Private mode or a sandboxed frame: behave as never sent.
		return null;
	}
}

function writeStorage(storage: Storage, key: string, value: string): void {
	try {
		storage.setItem(key, value);
	} catch {
		// Best-effort: the report may repeat next load.
	}
}

export { reportLanguageDemand, unsupportedLanguages };

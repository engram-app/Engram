import type { Locale } from "@/i18n/locales";

// Our locale codes are already BCP-47 tags, so a non-English app language goes to
// Intl as is. English returns the caller's `fallback`, which keeps each site's
// English output exactly what it was: "en-US" where it pinned that, the browser's
// own default (undefined) where it did not.
export function intlLocale(renderedLocale: Locale, fallback?: string): string | undefined {
	return renderedLocale === "en" ? fallback : renderedLocale;
}

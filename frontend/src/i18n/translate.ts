import type { Locale } from "./locales";

type PluralEn = PluralForms & { other: string };

const PLACEHOLDER = /\{(?<name>\w+)\}/gu;

export type PluralForms = Partial<Record<Intl.LDMLPluralRule, string>>;
export type Catalog = Record<string, string | PluralForms>;
export type Vars = Record<string, string | number>;

export function interpolate(template: string, vars?: Vars): string {
	if (!vars) {
		return template;
	}
	return template.replace(PLACEHOLDER, (match, name: string) =>
		Object.hasOwn(vars, name) ? String(vars[name]) : match,
	);
}

export function translate(catalog: Catalog, en: string, vars?: Vars): string {
	const hit = catalog[en];
	return interpolate(typeof hit === "string" ? hit : en, vars);
}

// The catalog key for a counted string is its English `other` form.
export function translatePlural(
	catalog: Catalog,
	locale: Locale,
	en: PluralForms & { other: string },
	count: number,
	vars?: Vars,
): string {
	const hit = catalog[en.other];
	const translated = typeof hit === "object";
	const forms = translated ? hit : en;
	const category = new Intl.PluralRules(translated ? locale : "en").select(count);
	return interpolate(forms[category] ?? forms.other ?? en.other, { ...vars, count });
}
// The shapes of `t` / `tn` from useT(), for helpers that cannot call the hook and
// take the translator as a parameter.
export type Translate = (en: string, vars?: Vars) => string;
export type Tn = (en: PluralEn, count: number, vars?: Vars) => string;

// The English identity translators: no catalog, so every key reads as itself.
export const englishT: Translate = (en, vars) => translate({}, en, vars);
export const englishTn: Tn = (en, count, vars) => translatePlural({}, "en", en, count, vars);

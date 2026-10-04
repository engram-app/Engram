import type { Locale } from "./locales";

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

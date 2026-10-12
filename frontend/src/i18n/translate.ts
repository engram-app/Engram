import { intlLocale } from "../lib/intl-locale";
import type { Locale } from "./locales";
import { type MsgKey, type UIText, untranslated } from "./ui-text";

const PLACEHOLDER = /\{(?<name>\w+)\}/gu;

export type PluralForms = Partial<Record<Intl.LDMLPluralRule, string>>;
export type Catalog = Record<string, string | PluralForms>;
export type Vars = Record<string, string | number>;

// The one place catalog text becomes UIText: every translator ends here.
export function interpolate(template: string, vars?: Vars): UIText {
	if (!vars) {
		return untranslated(template);
	}
	return untranslated(
		template.replace(PLACEHOLDER, (match, name: string) =>
			Object.hasOwn(vars, name) ? String(vars[name]) : match,
		),
	);
}

export function translate(catalog: Catalog, en: string, vars?: Vars): UIText {
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
): UIText {
	const hit = catalog[en.other];
	const translated = typeof hit === "object";
	const forms = translated ? hit : en;
	const category = new Intl.PluralRules(translated ? locale : "en").select(count);
	// {count} is always the number that picked the form, formatted for the locale ("1.234").
	const shown = new Intl.NumberFormat(intlLocale(locale)).format(count);
	return interpolate(forms[category] ?? forms.other ?? en.other, { ...vars, count: shown });
}
// A catalog key as a translator accepts it: a string literal the key scanner can
// read, or a MsgKey from msg(). A widened `string` (a variable, a template, a
// `Record<_, string>` lookup) resolves to MsgKey, so passing one fails tsc.
// `Record<never, never> extends Record<K, 1>` holds for `string` and for template types like
// `Hello ${string}` (both map to an index signature) but not for a finite literal.
export type Key<K extends string> = Record<never, never> extends Record<K, 1> ? MsgKey : K;
export type PluralKey<O extends string> = PluralForms & { other: Key<O> };

// The shapes of `t` / `tn` from useT(), for helpers that cannot call the hook and
// take the translator as a parameter.
export type Translate = <K extends string>(en: Key<K>, vars?: Vars) => UIText;
export type Tn = <O extends string>(en: PluralKey<O>, count: number, vars?: Vars) => UIText;

// The English identity translators: no catalog, so every key reads as itself.
export const englishT: Translate = (en, vars) => translate({}, en, vars);
export const englishTn: Tn = (en, count, vars) => translatePlural({}, "en", en, count, vars);

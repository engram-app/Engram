// Localized frontmatter KEY names for the named fields: `種類: 会議` is `type`.
// The English names are the source strings of a third translategemma run
// (scripts/i18n-translate.ts), whose catalogs land in locale/keys/<code>.json.
// The backend reads the same JSON at compile time (Engram.Notes.KeyAliases),
// so both sides resolve an alias from one generated source. Pure: callers
// supply the catalogs (no import.meta.glob here, the bun script imports this).
//
// `tags` is left out on purpose: Obsidian reads only `tags` as tags, so a
// localized alias would give a note tags its tag pane does not show.

import KEY_FIELDS from "./frontmatter-key-fields.json" with { type: "json" };
import type { Locale } from "./locales";

const NOTE =
	"A short frontmatter property name a user would type for this field; single word or compound, no spaces if natural in the language.";

// Each English key and what the field holds (for the translator), and the other
// English names a named field already answers to: one JSON the backend's
// Engram.Notes.KeyAliases reads at compile time too, so both sides agree.
const FIELDS = KEY_FIELDS.fields;

type FieldKey = keyof typeof FIELDS;

const FIELD_KEYS: readonly FieldKey[] = Object.keys(FIELDS).filter(isFieldKey);

const KEY_ENTRIES = FIELD_KEYS.map((key) => ({ key }));

const KEY_DESCRIPTIONS: Readonly<Record<string, string>> = Object.fromEntries(
	FIELD_KEYS.map((key) => [key, `${NOTE} The field holds ${FIELDS[key]}.`]),
);

// English names a named field already answers to (OKF aliases and the
// unfilterable reserved keys). A localized alias equal to one is ignored, so it
// can never point an English key at another field.
const ENGLISH = new Set<string>([...FIELD_KEYS, ...KEY_FIELDS.english]);

/** NFKC then lower case: `ｔｙｐｅ` and `Type` are `type`. Same as the backend. */
function normalizeKey(name: string): string {
	return name.normalize("NFKC").toLowerCase();
}

// Per field, its names in one locale. A list: the shape and the matcher take
// synonyms; the pipeline ships one word per field (the catalog's string).
type KeyCatalog = Readonly<Record<string, unknown>>;

function namesOf(catalog: KeyCatalog | undefined, field: FieldKey): string[] {
	const value = catalog?.[field];
	const names = Array.isArray(value) ? value : [value];
	return names.filter((n): n is string => typeof n === "string");
}

/** Normalized alias to its English field. A word two fields share in ONE locale
 *  (it `scadenza`) is dropped for both there, English still works; across
 *  locales the first in `order`, then field order, wins. Mirrors KeyAliases. */
function buildAliases(
	catalogs: Partial<Record<Locale, KeyCatalog>>,
	order: readonly Locale[],
): Map<string, FieldKey> {
	const aliases = new Map<string, FieldKey>();
	for (const code of order) {
		const pairs = FIELD_KEYS.flatMap((field) =>
			namesOf(catalogs[code], field)
				.map((name) => [normalizeKey(name), field] as const)
				.filter(([norm]) => !ENGLISH.has(norm)),
		);
		const fieldsOf = new Map<string, Set<FieldKey>>();
		for (const [norm, field] of pairs) {
			fieldsOf.set(norm, (fieldsOf.get(norm) ?? new Set()).add(field));
		}
		for (const [norm, field] of pairs) {
			if ((fieldsOf.get(norm)?.size ?? 0) === 1 && !aliases.has(norm)) {
				aliases.set(norm, field);
			}
		}
	}
	return aliases;
}

/** The named field `name` stands for (its English key in any casing or width, or a
 *  localized alias); undefined for any other key. */
function canonicalKey(name: string, aliases: ReadonlyMap<string, FieldKey>): FieldKey | undefined {
	const norm = normalizeKey(name);
	return isFieldKey(norm) ? norm : aliases.get(norm);
}

function isFieldKey(name: string): name is FieldKey {
	return Object.hasOwn(FIELDS, name);
}

export type { FieldKey, KeyCatalog };
export { buildAliases, canonicalKey, FIELD_KEYS, KEY_DESCRIPTIONS, KEY_ENTRIES, normalizeKey };

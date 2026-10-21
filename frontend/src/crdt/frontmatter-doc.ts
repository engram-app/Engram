import type * as Y from "yjs";
import type { Catalog } from "@/i18n/core/core";
import { buildAliases, canonicalKey } from "@/i18n/frontmatter-keys";
import { isMember } from "@/lib/is-member";
import { LOCALES, type Locale } from "@/i18n/locales";
import type { MsgKey } from "@/i18n/ui-text";
import { msg } from "../i18n/msg";
import { coerceValue, type PropertyType } from "../viewer/property-types";
import { emitFrontmatter } from "./frontmatter-codec";

const EMPTY_DEFAULT: Record<PropertyType, unknown> = {
	text: "",
	list: [],
	number: null,
	checkbox: false,
	date: "",
	datetime: "",
};

/**
 * Is this name already spoken for?
 *
 * Checking `values` alone is NOT enough: a DEGRADED key — one whose YAML we
 * could not model, kept verbatim — lives in `order` and the raw map and
 * deliberately never appears in `values`. Waving one of those through puts the
 * name in `order` twice, and since `emitFrontmatter` gives raws precedence the
 * other property's value stops being emitted at all. That corruption then
 * materialises and syncs out to the vault.
 */
function isTaken(doc: Y.Doc, key: string): boolean {
	return frontmatterMaps(doc).values.has(key) || rawMap(doc).has(key);
}

// The fields Engram READS rather than merely stores, and what each one buys
// you -- the source for the field highlight and the `?` panel beside the
// Properties heading. Spec 3.3b (flat schema): our own FLAT keys, each a
// typed search filter (`filterable`), plus `description`, which is embedded
// but not a filter. `Engram.Notes.FlatFields` and `OkfFields` read them.
//
// The aliases are not cosmetic: the backend reads OKF's names too (`date` for
// created, `modified`/`timestamp`/`generated.at` for updated, `resource` for
// source ...), and the flat key wins when a note has both. Listing only the
// flat names would tell the user an aliased note is not indexed. Nested
// aliases (`generated.at`, `verified[].by`) cannot be edited as a property
// here or in Obsidian; only a raw edit, MCP or an AI writes them.
// What the backend can actually read out of a date field. `parse_datetime/1`
// tries DateTime.from_iso8601 then Date.from_iso8601 and nothing else, so a
// plain date works and a datetime works ONLY with an offset. Notably the
// `datetime-local` picker emits `2026-08-29T14:30` -- no seconds, no offset --
// which neither accepts.
const OKF_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const OKF_DATETIME_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

export const OKF_FIELD_HELP: ReadonlyArray<{
	key: string;
	aliases: readonly string[];
	expects: readonly PropertyType[];
	expectsLabel: MsgKey;
	what: MsgKey;
	/** A typed search filter once the v5 payload format is on (spec 3.3b).
	 *  Data only: the panel claims no filter until search has one (#2083). */
	filterable?: true;
}> = [
	{
		key: "type",
		aliases: [],
		expects: ["text"],
		expectsLabel: msg("text"),
		what: msg("What kind of note this is. Search can filter on it."),
		filterable: true,
	},
	{
		key: "tags",
		aliases: [],
		// A bare `tags: work` is indexed too -- the scanner is a regex over the
		// raw line, not a list parser -- so "text" belongs here.
		expects: ["list", "text"],
		expectsLabel: msg("a list, or one name"),
		what: msg("Topics. Browsable and searchable across the vault."),
		filterable: true,
	},
	{
		key: "status",
		aliases: [],
		expects: ["text"],
		expectsLabel: msg("text"),
		what: msg("Where the note stands, such as draft or stable."),
		filterable: true,
	},
	{
		key: "author",
		aliases: ["generated.by"],
		expects: ["text"],
		expectsLabel: msg("text"),
		what: msg("Who wrote the note, a person or an agent."),
		filterable: true,
	},
	{
		key: "reviewed_by",
		aliases: ["verified[].by"],
		expects: ["text"],
		expectsLabel: msg("text"),
		what: msg("Who last checked the note."),
		filterable: true,
	},
	{
		key: "source",
		aliases: ["resource", "sources[]"],
		expects: ["list", "text"],
		expectsLabel: msg("a list, or one name"),
		what: msg("What the note is based on, usually a URL."),
		filterable: true,
	},
	{
		key: "project",
		aliases: [],
		expects: ["text"],
		expectsLabel: msg("text"),
		what: msg("The project the note belongs to."),
		filterable: true,
	},
	{
		key: "created",
		aliases: ["date"],
		expects: ["date", "datetime"],
		expectsLabel: msg("a date (YYYY-MM-DD)"),
		what: msg("When the note came into being."),
		filterable: true,
	},
	{
		key: "updated",
		aliases: ["modified", "timestamp", "generated.at"],
		expects: ["date", "datetime"],
		expectsLabel: msg("a date (YYYY-MM-DD)"),
		what: msg("When it last changed."),
		filterable: true,
	},
	{
		key: "reviewed",
		aliases: ["verified[].at"],
		expects: ["date", "datetime"],
		expectsLabel: msg("a date (YYYY-MM-DD)"),
		what: msg("When it was last checked."),
		filterable: true,
	},
	{
		key: "expires",
		aliases: ["stale_after"],
		expects: ["date", "datetime"],
		expectsLabel: msg("a date (YYYY-MM-DD)"),
		what: msg("When the note goes out of date."),
		filterable: true,
	},
	{
		key: "due",
		aliases: [],
		expects: ["date", "datetime"],
		expectsLabel: msg("a date (YYYY-MM-DD)"),
		what: msg("When the work in the note is due."),
		filterable: true,
	},
	{
		key: "priority",
		aliases: [],
		expects: ["number"],
		expectsLabel: msg("a number"),
		what: msg("How much the note matters, as a number."),
		filterable: true,
	},
	{
		key: "description",
		aliases: [],
		expects: ["text"],
		expectsLabel: msg("text"),
		what: msg("A one-line summary of the note."),
	},
];

// The named fields' localized key names (translategemma, locale/keys/*.json): the
// same catalogs the backend's KeyAliases reads, so `種類` is `type` on both sides.
const KEY_CATALOGS: Partial<Record<Locale, Catalog>> = Object.fromEntries(
	Object.entries(
		import.meta.glob<Catalog>(["../i18n/locale/keys/*.json", "!../i18n/locale/keys/state.json"], {
			eager: true,
			import: "default",
		}),
	).flatMap(([path, catalog]) => {
		const code = path.slice(path.lastIndexOf("/") + 1, -".json".length);
		return isMember(LOCALES, code) ? [[code, catalog]] : [];
	}),
);
const KEY_ALIASES = buildAliases(KEY_CATALOGS, LOCALES);

/** A named field's key name in `locale` (`種類` for `type` in ja); the English key
 *  when the locale has none. */
export function fieldKeyLabel(key: string, locale: Locale): string {
	const local = KEY_CATALOGS[locale]?.[key];
	return typeof local === "string" ? local : key;
}

/** The flat key an alias stands for; `undefined` for a flat key or an unknown name. */
export function okfAliasOf(name: string): string | undefined {
	return OKF_FIELD_HELP.find((f) => f.aliases.includes(name))?.key;
}

/** A nested OKF alias (`generated.at`, `verified[].by`): not editable as a property. */
export function isNestedAlias(name: string): boolean {
	return name.includes(".") || name.endsWith("[]");
}

export const CONTENT_KEY = "content";
export const FRONTMATTER_KEY = "frontmatter";
export const ORDER_KEY = "frontmatter_order";
export const TYPES_KEY = "frontmatter_types";

export interface FrontmatterMaps {
	values: Y.Map<string>;
	order: Y.Array<string>;
	types: Y.Map<string>;
}

export function frontmatterMaps(doc: Y.Doc): FrontmatterMaps {
	return {
		values: doc.getMap<string>(FRONTMATTER_KEY),
		order: doc.getArray<string>(ORDER_KEY),
		types: doc.getMap<string>(TYPES_KEY),
	};
}

export interface PropertyRow {
	key: string;
	value: unknown;
	typeOverride: string | null;
}

export function readRows(doc: Y.Doc): PropertyRow[] {
	const { values, order, types } = frontmatterMaps(doc);
	return order.toArray().map((key) => {
		const raw = values.get(key);
		let value: unknown = raw;
		if (typeof raw === "string") {
			try {
				value = JSON.parse(raw);
			} catch {
				value = raw;
			}
		}
		return { key, value, typeOverride: types.get(key) ?? null };
	});
}

export function setValue(doc: Y.Doc, key: string, value: unknown): void {
	const { values } = frontmatterMaps(doc);
	const encoded = JSON.stringify(value);
	if (values.get(key) === encoded) {
		return;
	}
	values.set(key, encoded);
}

export function addKey(doc: Y.Doc, key: string, type: PropertyType): boolean {
	const trimmed = key.trim();
	if (trimmed === "") {
		return false;
	}
	const { values, order, types } = frontmatterMaps(doc);
	if (isTaken(doc, trimmed)) {
		return false;
	}
	doc.transact(() => {
		values.set(trimmed, JSON.stringify(EMPTY_DEFAULT[type]));
		types.set(trimmed, type);
		order.push([trimmed]);
	});
	return true;
}

export function removeKey(doc: Y.Doc, key: string): void {
	const { values, order, types } = frontmatterMaps(doc);
	doc.transact(() => {
		values.delete(key);
		types.delete(key);
		const idx = order.toArray().indexOf(key);
		if (idx >= 0) {
			order.delete(idx, 1);
		}
	});
}

/**
 * Rename a property, keeping its value, its type and where it sits.
 *
 * Deliberately NOT removeKey + addKey: that would drop the value and push the
 * property to the end of the order, so renaming a key would silently reshuffle
 * the frontmatter. One transaction, so peers never observe the old and new
 * names at once.
 */
export function renameKey(doc: Y.Doc, from: string, to: string): boolean {
	const trimmed = to.trim();
	const { values, order, types } = frontmatterMaps(doc);
	if (trimmed === "" || trimmed === from || !values.has(from) || isTaken(doc, trimmed)) {
		return false;
	}
	doc.transact(() => {
		const value = values.get(from);
		const type = types.get(from);
		if (value !== undefined) {
			values.set(trimmed, value);
		}
		if (type !== undefined) {
			types.set(trimmed, type);
		}
		values.delete(from);
		types.delete(from);
		const idx = order.toArray().indexOf(from);
		if (idx >= 0) {
			order.delete(idx, 1);
			order.insert(idx, [trimmed]);
		} else {
			order.push([trimmed]);
		}
	});
	return true;
}

export function setType(doc: Y.Doc, key: string, type: PropertyType): void {
	const { values, types } = frontmatterMaps(doc);
	const rows = readRows(doc);
	const row = rows.find((r) => r.key === key);
	doc.transact(() => {
		types.set(key, type);
		if (row) {
			values.set(key, JSON.stringify(coerceValue(row.value, type)));
		}
	});
}

export const RAW_FRONTMATTER_KEY = "frontmatter_raw";

export function rawMap(doc: Y.Doc): Y.Map<string> {
	return doc.getMap<string>(RAW_FRONTMATTER_KEY);
}

export function readRaws(doc: Y.Doc): Record<string, string> {
	const out: Record<string, string> = {};
	rawMap(doc).forEach((v, k) => {
		out[k] = v;
	});
	return out;
}

/** Emit the frontmatter block (inner YAML, no fences) from the live maps. */
export function emitFrontmatterText(doc: Y.Doc): string {
	const { values, order } = frontmatterMaps(doc);
	const valuesRec: Record<string, string> = {};
	values.forEach((v, k) => {
		valuesRec[k] = v;
	});
	return emitFrontmatter(order.toArray(), valuesRec, readRaws(doc));
}

/**
 * Apply a parsed frontmatter block to the Y.Map with a MINIMAL per-key diff, in
 * one transaction. `parsed.values` are canonical-JSON strings (from
 * parseFrontmatter) and are stored as-is — do NOT re-JSON.stringify. A concurrent
 * pill edit to an untouched key is never clobbered; keys held in frontmatter_raw
 * are preserved. Types are left to the pills.
 */
export function applyParsedFrontmatter(
	doc: Y.Doc,
	parsed: { order: string[]; values: Record<string, string> },
): void {
	const { values, order } = frontmatterMaps(doc);
	const raws = rawMap(doc);
	doc.transact(() => {
		for (const key of Object.keys(parsed.values)) {
			const next = parsed.values[key]!;
			if (values.get(key) !== next) {
				values.set(key, next);
			}
		}
		for (const key of [...values.keys()]) {
			if (!(key in parsed.values || raws.has(key))) {
				values.delete(key);
			}
		}
		const current = order.toArray();
		const changed =
			current.length !== parsed.order.length || current.some((k, i) => k !== parsed.order[i]);
		if (changed) {
			order.delete(0, order.length);
			if (parsed.order.length > 0) {
				order.insert(0, parsed.order);
			}
		}
	});
}

/** Would the backend actually index this property as the field it is named for?
 *
 *  Not "is the key spelled right" and not "does the widget render it as the
 *  right type". Both of those were tried and both lied:
 *
 *    - matching the key case-INSENSITIVELY once highlighted `Type:`, which the
 *      backend then read literally. It now folds a named field's key (NFKC, lower
 *      case, localized names: `KeyAliases`), so this does the same through
 *      `canonicalKey`; `tags` and the OKF aliases still match as written.
 *    - trusting the rendered type highlighted `created` holding the
 *      datetime-local picker's own output, which `parse_datetime/1` rejects,
 *      and left `tags: work` muted even though the tag scanner does index an
 *      inline scalar.
 *    - and an EMPTY value highlighted from the moment a key was added, though
 *      `string_field/1` refuses "" outright.
 *
 *  So this asks the same questions the backend asks, on the value. Getting it
 *  wrong in the generous direction is the worse failure: the whole point is
 *  that a mismatch is silently unindexed, and a highlight that over-promises
 *  removes the only signal the user gets. */
export function isOkfMatch(key: string, type: PropertyType, value: unknown): boolean {
	const name = canonicalKey(key, KEY_ALIASES) ?? key;
	const field = OKF_FIELD_HELP.find((f) => f.key === name || f.aliases.includes(name));
	if (field === undefined || !field.expects.includes(type)) {
		return false;
	}
	if (field.expects.includes("number")) {
		return typeof value === "number" && Number.isFinite(value);
	}
	if (field.key === "tags" || field.key === "source") {
		// `helpers.ex` accepts a YAML list AND a bare inline scalar, so both index.
		if (Array.isArray(value)) {
			return value.some((v) => String(v).trim() !== "");
		}
		return typeof value === "string" && value.trim() !== "";
	}
	if (field.expects.includes("date")) {
		return typeof value === "string" && (OKF_DATE_RE.test(value) || OKF_DATETIME_RE.test(value));
	}
	// type / description / resource: `string_field/1` takes a non-empty binary.
	return typeof value === "string" && value !== "";
}

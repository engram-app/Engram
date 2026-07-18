import type * as Y from "yjs";
import { emitFrontmatter } from "./frontmatter-codec";
import { coerceValue, type PropertyType } from "../viewer/property-types";

const EMPTY_DEFAULT: Record<PropertyType, unknown> = {
	text: "",
	list: [],
	number: null,
	checkbox: false,
	date: "",
	datetime: "",
};

// OKF v0.1 standard keys, pinned to the top of the properties widget in
// spec order. Custom keys follow in their user-defined order.
const OKF_KEY_ORDER = ["type", "description", "resource", "timestamp", "created", "tags"] as const;

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
	if (values.has(trimmed)) {
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

export function moveKey(doc: Y.Doc, key: string, dir: "up" | "down"): void {
	const { order } = frontmatterMaps(doc);
	const arr = order.toArray();
	const idx = arr.indexOf(key);
	if (idx < 0) {
		return;
	}
	const target = dir === "up" ? idx - 1 : idx + 1;
	if (target < 0 || target >= arr.length) {
		return;
	}
	doc.transact(() => {
		order.delete(idx, 1);
		order.insert(target, [key]);
	});
}

export function sortRowsOkfFirst(rows: PropertyRow[]): PropertyRow[] {
	const rank = (key: string) => {
		const i = (OKF_KEY_ORDER as readonly string[]).indexOf(key);
		return i === -1 ? OKF_KEY_ORDER.length : i;
	};
	// Array.prototype.sort is stable: equal-rank (custom) keys keep order.
	return [...rows].sort((a, b) => rank(a.key) - rank(b.key));
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
			if (values.get(key) !== next) values.set(key, next);
		}
		for (const key of [...values.keys()]) {
			if (!(key in parsed.values) && !raws.has(key)) values.delete(key);
		}
		const current = order.toArray();
		const changed =
			current.length !== parsed.order.length || current.some((k, i) => k !== parsed.order[i]);
		if (changed) {
			order.delete(0, order.length);
			if (parsed.order.length > 0) order.insert(0, parsed.order);
		}
	});
}

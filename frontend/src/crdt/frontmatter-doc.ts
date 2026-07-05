import type * as Y from "yjs";
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

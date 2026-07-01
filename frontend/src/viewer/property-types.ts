// Pure type model for the frontmatter properties widget. No React, no Yjs.
// Values here are already-decoded JS values (the result of JSON.parse on a
// Y.Map("frontmatter") entry), not YAML text.

export type PropertyType = "text" | "list" | "number" | "checkbox" | "date" | "datetime";

const ALL: readonly PropertyType[] = ["text", "list", "number", "checkbox", "date", "datetime"];

const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;
const DATE_TIME = /^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}/;

export function isPropertyType(s: unknown): s is PropertyType {
	return typeof s === "string" && (ALL as readonly string[]).includes(s);
}

export function inferType(value: unknown): PropertyType {
	if (Array.isArray(value)) {
		return "list";
	}
	if (typeof value === "number") {
		return "number";
	}
	if (typeof value === "boolean") {
		return "checkbox";
	}
	if (typeof value === "string") {
		if (DATE_TIME.test(value)) {
			return "datetime";
		}
		if (DATE_ONLY.test(value)) {
			return "date";
		}
		return "text";
	}
	return "text";
}

export function effectiveType(value: unknown, override?: string | null): PropertyType {
	return isPropertyType(override) ? override : inferType(value);
}

export function coerceValue(value: unknown, to: PropertyType): unknown {
	switch (to) {
		case "list":
			if (Array.isArray(value)) {
				return value;
			}
			if (value === "" || value == null) {
				return [];
			}
			return [scalarToString(value)];
		case "text":
			if (Array.isArray(value)) {
				return value.map(scalarToString).join(", ");
			}
			if (value == null) {
				return "";
			}
			return scalarToString(value);
		case "number": {
			const n = typeof value === "number" ? value : Number(scalarToString(value));
			return Number.isFinite(n) ? n : null;
		}
		case "checkbox":
			if (typeof value === "boolean") {
				return value;
			}
			return Boolean(value) && scalarToString(value) !== "false" && scalarToString(value) !== "";
		case "date":
		case "datetime":
			return value == null ? "" : scalarToString(value);
		default:
			return value;
	}
}

function scalarToString(v: unknown): string {
	if (v == null) {
		return "";
	}
	if (typeof v === "string") {
		return v;
	}
	return String(v);
}

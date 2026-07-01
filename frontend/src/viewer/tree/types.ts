export type TreeItem =
	| { kind: "folder"; id: string; path: string; name: string; count: number }
	| { kind: "note"; id: string; path: string; title: string; ext: string | null }
	| { kind: "attachment"; id: string; path: string; mime: string; size: number };

export type ItemId = string;

export const ROOT_ID: ItemId = "root";

export function formatItemId(
	input: { kind: "folder" | "note"; id: string } | { kind: "attachment"; path: string },
): ItemId {
	if (input.kind === "attachment") {
		const encoded = input.path.split("/").map(encodeURIComponent).join("/");
		return `a:${encoded}`;
	}
	return `${input.kind === "folder" ? "f" : "n"}:${input.id}`;
}

export type ParsedItemId =
	| { kind: "folder"; id: string }
	| { kind: "note"; id: string }
	| { kind: "attachment"; path: string }
	| { kind: "root" };

export function parseItemId(id: ItemId): ParsedItemId {
	if (id === ROOT_ID) return { kind: "root" };
	// uuid contains '-' but not ':' — splitting on the first ':' keeps
	// the rest of the id intact as the uuid string.
	const colon = id.indexOf(":");
	if (colon < 0) throw new Error(`Unknown tree item id: ${id}`);
	const prefix = id.slice(0, colon);
	const rest = id.slice(colon + 1);
	if (rest.length === 0) throw new Error(`Unknown tree item id: ${id}`);
	if (prefix === "f") return { kind: "folder", id: rest };
	if (prefix === "n") return { kind: "note", id: rest };
	if (prefix === "a") {
		const path = rest.split("/").map(decodeURIComponent).join("/");
		return { kind: "attachment", path };
	}
	throw new Error(`Unknown tree item id: ${id}`);
}

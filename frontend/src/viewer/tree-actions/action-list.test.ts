import { describe, expect, it } from "vitest";
import { actionsFor } from "./action-list";

describe("actionsFor", () => {
	it("file actions: rename, move, duplicate, copy-wikilink, delete", () => {
		const ids = actionsFor({ kind: "file" }).map((a) => a.id);
		expect(ids).toEqual(["rename", "move", "duplicate", "copy-wikilink", "delete"]);
	});

	it("folder actions: rename, move, delete (no duplicate, no wikilink)", () => {
		const ids = actionsFor({ kind: "folder" }).map((a) => a.id);
		expect(ids).toEqual(["rename", "move", "delete"]);
	});

	it("labels match design spec verbatim", () => {
		expect(actionsFor({ kind: "file" }).map((a) => a.label)).toEqual([
			"Rename",
			"Move to…",
			"Duplicate",
			"Copy wikilink",
			"Delete",
		]);
	});

	it("delete is the only destructive action", () => {
		for (const kind of ["file", "folder"] as const) {
			const destructive = actionsFor({ kind }).filter((a) => a.destructive);
			expect(destructive.map((a) => a.id)).toEqual(["delete"]);
		}
	});
});

import { describe, expect, it } from "vitest";
import { actionsFor } from "./action-list";

describe("actionsFor", () => {
	it("file actions: rename, move, duplicate, copy-wikilink, delete", () => {
		const ids = actionsFor({ kind: "file" }).map((a) => a.id);
		expect(ids).toEqual(["rename", "move", "duplicate", "copy-wikilink", "delete"]);
	});

	// Creation comes first: a folder's most common right-click intent is "put
	// something in here", and it targets THIS folder rather than the toolbar's
	// active one. No duplicate — copying a folder needs a recursive server-side
	// copy that doesn't exist yet.
	it("folder actions: new-note, new-folder, rename, move, delete", () => {
		const ids = actionsFor({ kind: "folder" }).map((a) => a.id);
		expect(ids).toEqual(["new-note", "new-folder", "rename", "move", "delete"]);
	});

	it("folder labels name the target so they can't read as global actions", () => {
		expect(actionsFor({ kind: "folder" }).map((a) => a.label)).toEqual([
			"New note here",
			"New subfolder",
			"Rename",
			"Move to…",
			"Delete",
		]);
	});

	// A derived folder (one `/api/folders` returned with a null id, so it carries
	// a `syn:` id) has no backend record. Move and delete are id-keyed and would
	// fail, but creating inside it is path-keyed and works — so it gets a menu
	// with just those, rather than no menu at all and the browser's instead.
	it("synthetic folder actions: creation only", () => {
		const ids = actionsFor({ kind: "folder", synthetic: true }).map((a) => a.id);
		expect(ids).toEqual(["new-note", "new-folder"]);
	});

	it("synthetic folders never offer id-keyed actions", () => {
		const ids = actionsFor({ kind: "folder", synthetic: true }).map((a) => a.id);
		for (const idKeyed of ["move", "delete", "rename"]) {
			expect(ids).not.toContain(idKeyed);
		}
	});

	it("creation actions stay off files and attachments", () => {
		for (const kind of ["file", "attachment"] as const) {
			const ids = actionsFor({ kind }).map((a) => a.id);
			expect(ids).not.toContain("new-note");
			expect(ids).not.toContain("new-folder");
		}
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

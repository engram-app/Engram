import { describe, expect, it } from "vitest";
import { ACTION_ICONS, actionsFor, noteMenuActions } from "./action-list";

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

describe("noteMenuActions", () => {
	it("lists the three view modes, the file actions, and add-property", () => {
		const ids = noteMenuActions("rendered").map((a) => a.id);
		expect(ids).toEqual([
			"view-rendered",
			"view-raw",
			"view-reading",
			"rename",
			"move",
			"duplicate",
			"copy-wikilink",
			"add-property",
			"delete",
		]);
	});

	it("marks the active mode so the menu can show a checkmark", () => {
		const raw = noteMenuActions("raw").find((a) => a.id === "view-raw");
		const rendered = noteMenuActions("raw").find((a) => a.id === "view-rendered");
		expect(raw?.active).toBe(true);
		expect(rendered?.active).toBe(false);
	});

	// ActionDrawer renders ACTION_ICONS[id] unconditionally — a missing entry
	// is a crash, not a degraded menu.
	it("has an icon for every action it can render", () => {
		for (const action of noteMenuActions("rendered")) {
			expect(ACTION_ICONS[action.id]).toBeDefined();
		}
	});

	// The tree's menus must not grow the new entries.
	it("leaves the tree's file menu unchanged", () => {
		const ids = actionsFor({ kind: "file" }).map((a) => a.id);
		expect(ids).toEqual(["rename", "move", "duplicate", "copy-wikilink", "delete"]);
	});
});

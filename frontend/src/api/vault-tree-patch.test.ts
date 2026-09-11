import { describe, expect, it } from "vitest";
import type { VaultTree } from "./queries";
import {
	isUnder,
	moveFolders,
	moveNotes,
	removeFolders,
	removeNotes,
	renameFolders,
	renameNotes,
	upsertNote,
} from "./vault-tree-patch";

const note = (id: string, path: string) => ({
	id,
	path,
	created_at: "2026-01-01T00:00:00Z",
	updated_at: "2026-01-01T00:00:00Z",
});

const att = (id: string, path: string) => ({
	id,
	path,
	mime_type: "image/png",
	size_bytes: 1,
	mtime: 0,
	updated_at: "2026-01-01T00:00:00Z",
});

// Two top-level folders, one nested, one marker-only empty folder, and a
// decoy (`Archive2024`) whose name shares a prefix with `Archive`.
const TREE: VaultTree = {
	folders: [
		{ id: "m-arch", name: "Archive", count: 0, parent_id: null },
		{ id: null, name: "Archive/2023", count: 0, parent_id: null },
		{ id: "m-arch24", name: "Archive2024", count: 0, parent_id: null },
		{ id: "m-empty", name: "Empty", count: 0, parent_id: null },
	],
	notes: [
		note("n-root", "top.md"),
		note("n1", "Archive/a.md"),
		note("n2", "Archive/b.md"),
		note("n3", "Archive/2023/old.md"),
		note("n4", "Archive2024/decoy.md"),
	],
	attachments: [att("a1", "Archive/pic.png"), att("a2", "Archive/2023/scan.png")],
};

const paths = (t: VaultTree) => t.notes.map((n) => n.path).sort();
const countOf = (t: VaultTree, name: string) => t.folders.find((f) => f.name === name)?.count;

describe("isUnder", () => {
	it("does not treat a shared name prefix as nesting", () => {
		expect(isUnder("Archive2024/decoy.md", "Archive")).toBe(false);
		expect(isUnder("Archive/2023", "Archive")).toBe(true);
		expect(isUnder("Archive", "Archive")).toBe(true);
	});
});

describe("counts", () => {
	// Nothing calls a decrement/increment helper: count is derived from `notes`
	// after every edit, which is what makes the source/destination bookkeeping
	// impossible to get wrong.
	it("derives folder counts from the notes present", () => {
		const t = upsertNote(TREE, note("n5", "Archive/c.md"));
		expect(countOf(t, "Archive")).toBe(3);
		expect(countOf(t, "Archive/2023")).toBe(1);
		expect(countOf(t, "Empty")).toBe(0);
	});

	it("moves the count with the note, both sides at once", () => {
		const t = moveNotes(TREE, ["n1"], "Empty");
		expect(countOf(t, "Archive")).toBe(1);
		expect(countOf(t, "Empty")).toBe(1);
	});
});

describe("notes", () => {
	it("replaces the row on an upsert of a known id", () => {
		const t = upsertNote(TREE, note("n1", "Archive/renamed.md"));
		expect(t.notes.filter((n) => n.id === "n1")).toHaveLength(1);
		expect(paths(t)).toContain("Archive/renamed.md");
	});

	it("skips a rename of an id the tree has never seen", () => {
		const t = renameNotes(TREE, [{ id: "ghost", newPath: "Archive/ghost.md" }]);
		expect(paths(t)).toEqual(paths(TREE));
	});

	it("keeps the filename when moving to another folder", () => {
		const t = moveNotes(TREE, ["n1", "n3"], "Empty");
		expect(paths(t)).toContain("Empty/a.md");
		expect(paths(t)).toContain("Empty/old.md");
	});

	it("moves to the vault root", () => {
		expect(paths(moveNotes(TREE, ["n1"], ""))).toContain("a.md");
	});

	it("removes by id", () => {
		expect(removeNotes(TREE, ["n1", "n2"]).notes.map((n) => n.id)).toEqual(["n-root", "n3", "n4"]);
	});
});

describe("folders", () => {
	it("carries notes, attachments and descendant folders through a rename", () => {
		const t = renameFolders(TREE, [{ oldPath: "Archive", newPath: "Vault/Old" }]);
		expect(paths(t)).toEqual(
			[
				"Vault/Old/a.md",
				"Vault/Old/b.md",
				"Vault/Old/2023/old.md",
				"Archive2024/decoy.md",
				"top.md",
			].sort(),
		);
		expect(t.folders.map((f) => f.name).sort()).toEqual(
			["Vault/Old", "Vault/Old/2023", "Archive2024", "Empty"].sort(),
		);
		expect(t.attachments.map((a) => a.path).sort()).toEqual(
			["Vault/Old/pic.png", "Vault/Old/2023/scan.png"].sort(),
		);
	});

	it("leaves a prefix-sharing sibling alone", () => {
		const t = renameFolders(TREE, [{ oldPath: "Archive", newPath: "Old" }]);
		expect(paths(t)).toContain("Archive2024/decoy.md");
		expect(t.folders.map((f) => f.name)).toContain("Archive2024");
	});

	it("applies only the outermost move when a batch nests", () => {
		const t = renameFolders(TREE, [
			{ oldPath: "Archive", newPath: "A" },
			{ oldPath: "Archive/2023", newPath: "B" },
		]);
		expect(paths(t)).toContain("A/2023/old.md");
		expect(paths(t)).not.toContain("B/old.md");
	});

	it("deletes the whole subtree", () => {
		const t = removeFolders(TREE, ["Archive"]);
		expect(paths(t)).toEqual(["Archive2024/decoy.md", "top.md"]);
		expect(t.folders.map((f) => f.name).sort()).toEqual(["Archive2024", "Empty"]);
		expect(t.attachments).toEqual([]);
	});

	it("moves a folder under a new parent, keeping its leaf name", () => {
		const t = moveFolders(TREE, ["Archive/2023"], "Empty");
		expect(paths(t)).toContain("Empty/2023/old.md");
		expect(countOf(t, "Empty/2023")).toBe(1);
	});
});

describe("immutability", () => {
	// React Query compares by reference to decide whether to notify observers,
	// so an in-place edit applies and renders nothing.
	it("never mutates the input tree", () => {
		const before = JSON.stringify(TREE);
		removeNotes(TREE, ["n1"]);
		moveNotes(TREE, ["n1"], "Empty");
		renameFolders(TREE, [{ oldPath: "Archive", newPath: "X" }]);
		removeFolders(TREE, ["Archive"]);
		upsertNote(TREE, note("n9", "z.md"));
		expect(JSON.stringify(TREE)).toBe(before);
	});
});

import { expect, test } from "vitest";
import { dropFolderFor, folderRegion } from "./file-drop-region";

test("a file can only land in a folder: a folder row is itself, any other row is its parent", () => {
	expect(dropFolderFor({ kind: "folder", path: "A/B" })).toBe("A/B");
	expect(dropFolderFor({ kind: "note", path: "A/B/n.md" })).toBe("A/B");
	expect(dropFolderFor({ kind: "attachment", path: "pic.png" })).toBe("");
});

const rows = [
	{ kind: "folder", path: "A" },
	{ kind: "folder", path: "A/B" },
	{ kind: "note", path: "A/B/n.md" },
	{ kind: "note", path: "A/m.md" },
	{ kind: "folder", path: "AB" },
	{ kind: "note", path: "z.md" },
];

test("the region is the folder row plus every row beneath it, and no sibling that shares a prefix", () => {
	expect(folderRegion(rows, "A")).toEqual({ start: 0, end: 3 });
	expect(folderRegion(rows, "A/B")).toEqual({ start: 1, end: 2 });
	expect(folderRegion(rows, "AB")).toEqual({ start: 4, end: 4 });
});

test("the root and unknown folders have no region", () => {
	expect(folderRegion(rows, "")).toBeNull();
	expect(folderRegion(rows, "nope")).toBeNull();
});

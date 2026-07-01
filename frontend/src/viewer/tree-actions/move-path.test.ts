import { describe, expect, it } from "vitest";
import { isValidMoveTarget, newPathAfterMove } from "./move-path";

describe("isValidMoveTarget", () => {
	it("rejects moving a folder onto itself", () => {
		expect(isValidMoveTarget({ kind: "folder", path: "src" }, "src")).toBe(false);
	});
	it("rejects moving a folder into its descendant", () => {
		expect(isValidMoveTarget({ kind: "folder", path: "src" }, "src/sub")).toBe(false);
	});
	it("rejects a no-op move (file already in target folder)", () => {
		expect(isValidMoveTarget({ kind: "file", path: "src/a.md" }, "src")).toBe(false);
	});
	it("accepts moving a file to a different folder", () => {
		expect(isValidMoveTarget({ kind: "file", path: "src/a.md" }, "dst")).toBe(true);
	});
	it("accepts moving a file to root", () => {
		expect(isValidMoveTarget({ kind: "file", path: "src/a.md" }, "")).toBe(true);
	});
	it("accepts moving a folder to a sibling parent", () => {
		expect(isValidMoveTarget({ kind: "folder", path: "src/a" }, "dst")).toBe(true);
	});
});

describe("newPathAfterMove", () => {
	it("moves a file to a target folder", () => {
		expect(newPathAfterMove("src/a.md", "dst")).toBe("dst/a.md");
	});
	it("moves a file to root", () => {
		expect(newPathAfterMove("src/a.md", "")).toBe("a.md");
	});
	it("moves a folder to a target folder", () => {
		expect(newPathAfterMove("src/sub", "dst")).toBe("dst/sub");
	});
});

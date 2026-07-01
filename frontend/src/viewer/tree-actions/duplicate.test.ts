import { describe, expect, it } from "vitest";
import { nextCopyName } from "./duplicate";

describe("nextCopyName", () => {
	it('adds " (copy)" suffix before extension on first dup', () => {
		expect(nextCopyName("a.md", new Set(["a.md"]))).toBe("a (copy).md");
	});
	it('bumps to " (copy 2)" when copy already exists', () => {
		expect(nextCopyName("a.md", new Set(["a.md", "a (copy).md"]))).toBe("a (copy 2).md");
	});
	it("handles extensionless names", () => {
		expect(nextCopyName("notes", new Set(["notes"]))).toBe("notes (copy)");
	});
	it("preserves folder prefix", () => {
		expect(nextCopyName("src/a.md", new Set(["src/a.md"]))).toBe("src/a (copy).md");
	});
});

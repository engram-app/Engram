import { describe, expect, it } from "vitest";
import { formatItemId, parseItemId, ROOT_ID } from "./types";

describe("item id helpers", () => {
	it("round-trips folder id", () => {
		expect(
			parseItemId(formatItemId({ kind: "folder", id: "01923a4b-cdef-7000-89ab-cdef01234567" })),
		).toEqual({ kind: "folder", id: "01923a4b-cdef-7000-89ab-cdef01234567" });
	});

	it("round-trips note id", () => {
		expect(
			parseItemId(formatItemId({ kind: "note", id: "01923a4b-cdef-7000-89ab-cdef01234567" })),
		).toEqual({ kind: "note", id: "01923a4b-cdef-7000-89ab-cdef01234567" });
	});

	it("parseItemId rejects unknown prefix", () => {
		expect(() => parseItemId("x:1")).toThrow();
	});

	it("root sentinel returns kind: root", () => {
		expect(parseItemId(ROOT_ID)).toEqual({ kind: "root" });
	});
});

describe("attachment item ids", () => {
	it("round-trips a simple attachment path", () => {
		const id = formatItemId({ kind: "attachment", path: "img/a.png" });
		expect(id).toBe("a:img/a.png");
		expect(parseItemId(id)).toEqual({ kind: "attachment", path: "img/a.png" });
	});

	it("round-trips a path with spaces and unicode", () => {
		const path = "My Files/diagram (final).pdf";
		const id = formatItemId({ kind: "attachment", path });
		expect(parseItemId(id)).toEqual({ kind: "attachment", path });
	});

	it("keeps slashes as path separators, not encoded", () => {
		const id = formatItemId({ kind: "attachment", path: "a/b/c.png" });
		expect(id.startsWith("a:")).toBe(true);
		expect(parseItemId(id)).toEqual({ kind: "attachment", path: "a/b/c.png" });
	});
});

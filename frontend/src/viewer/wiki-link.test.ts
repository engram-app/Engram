import { describe, expect, test } from "vitest";
import { parseWikiTarget, resolveWikiTarget, wikiHref } from "./wiki-link";

describe("parseWikiTarget", () => {
	test("plain path has no hash", () => {
		expect(parseWikiTarget("Folder/Note")).toEqual({ page: "Folder/Note", hash: "" });
	});

	test("heading becomes a github-slugged hash", () => {
		expect(parseWikiTarget("Note#My Heading")).toEqual({ page: "Note", hash: "#my-heading" });
	});

	test("bare heading targets the current page", () => {
		expect(parseWikiTarget("#Other Heading")).toEqual({ page: "", hash: "#other-heading" });
	});

	test("surrounding whitespace is trimmed", () => {
		expect(parseWikiTarget("  Note  ")).toEqual({ page: "Note", hash: "" });
	});
});

describe("resolveWikiTarget", () => {
	const notes = [
		{ id: "root", path: "Note.md" },
		{ id: "b", path: "B/Note.md" },
		{ id: "deep", path: "Deep/Sub/Only Here.md" },
		{ id: "cased", path: "Folder/CaSed.md" },
	];

	test("exact path without extension", () => {
		expect(resolveWikiTarget("B/Note", notes)?.id).toBe("b");
	});

	test("exact path with extension", () => {
		expect(resolveWikiTarget("B/Note.md", notes)?.id).toBe("b");
	});

	test("exact path beats a basename match elsewhere", () => {
		expect(resolveWikiTarget("Note", notes)?.id).toBe("root");
	});

	test("basename resolves vault-wide", () => {
		expect(resolveWikiTarget("Only Here", notes)?.id).toBe("deep");
	});

	test("basename picks the shortest path on duplicates", () => {
		const dupes = [
			{ id: "long", path: "A/B/C/Dup.md" },
			{ id: "short", path: "A/Dup.md" },
		];
		expect(resolveWikiTarget("Dup", dupes)?.id).toBe("short");
	});

	test("matching is case-insensitive", () => {
		expect(resolveWikiTarget("folder/cased", notes)?.id).toBe("cased");
		expect(resolveWikiTarget("CASED", notes)?.id).toBe("cased");
	});

	test("unknown target resolves to null", () => {
		expect(resolveWikiTarget("Nope", notes)).toBeNull();
	});

	test("empty page resolves to null", () => {
		expect(resolveWikiTarget("", notes)).toBeNull();
	});
});

describe("wikiHref", () => {
	test("routes into the vault wiki resolver, segment-encoded", () => {
		expect(wikiHref("Folder/My Note", "my-vault")).toBe("/my-vault/wiki/Folder/My%20Note");
	});

	test("carries the heading as a slugged hash", () => {
		expect(wikiHref("Note#Some Heading", "v")).toBe("/v/wiki/Note#some-heading");
	});

	test("bare heading links stay on the current page", () => {
		expect(wikiHref("#Some Heading", "v")).toBe("#some-heading");
	});
});

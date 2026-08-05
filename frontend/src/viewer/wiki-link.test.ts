import { describe, expect, test } from "vitest";
import {
	buildWikiMap,
	parseWikiTarget,
	resolveWikiTarget,
	wikiCreatePath,
	wikiHref,
} from "./wiki-link";

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

	test("no vault slug renders an inert anchor", () => {
		expect(wikiHref("My Note", undefined)).toBe("#");
	});
});

describe("wikiCreatePath", () => {
	test("bare target creates at the vault root", () => {
		expect(wikiCreatePath("songebobsss")).toEqual({ folder: "", name: "songebobsss.md" });
	});

	test("path-qualified target splits into folder + filename", () => {
		expect(wikiCreatePath("folder/sub/Name")).toEqual({ folder: "folder/sub", name: "Name.md" });
	});

	test("strips a #heading segment before deriving the path", () => {
		expect(wikiCreatePath("folder/Name#Some Heading")).toEqual({
			folder: "folder",
			name: "Name.md",
		});
	});

	test("strips a redundant .md extension rather than doubling it", () => {
		expect(wikiCreatePath("Name.md")).toEqual({ folder: "", name: "Name.md" });
	});

	test("trims surrounding whitespace", () => {
		expect(wikiCreatePath("  Name  ")).toEqual({ folder: "", name: "Name.md" });
	});
});

describe("wikiHref with resolver map", () => {
	const map = buildWikiMap([
		{
			target_text: "My Note",
			target_note_id: "n-1",
			target_attachment_id: null,
			target_path: "a/My Note.md",
			alias: null,
			anchor: null,
			link_type: "wikilink",
			dangling: false,
		},
		{
			target_text: "Ghost",
			target_note_id: null,
			target_attachment_id: null,
			target_path: null,
			alias: null,
			anchor: null,
			link_type: "wikilink",
			dangling: true,
		},
	]);

	test("resolved target links straight to the note id", () => {
		expect(wikiHref("My Note", "v", map)).toBe("/v/n-1");
	});

	test("lookup is case-insensitive and keeps the heading hash", () => {
		expect(wikiHref("my note#Some Heading", "v", map)).toBe("/v/n-1#some-heading");
	});

	test("dangling target falls back to the wiki resolver route", () => {
		expect(wikiHref("Ghost", "v", map)).toBe("/v/wiki/Ghost");
	});

	test("target absent from the map falls back to the wiki resolver route", () => {
		expect(wikiHref("Brand New", "v", map)).toBe("/v/wiki/Brand%20New");
	});

	test("no map behaves exactly as before", () => {
		expect(wikiHref("My Note", "v")).toBe("/v/wiki/My%20Note");
	});
});

describe("wikiHref layered manifest fallback", () => {
	const map = buildWikiMap([
		{
			target_text: "My Note",
			target_note_id: "edge-id",
			target_attachment_id: null,
			target_path: "a/My Note.md",
			alias: null,
			anchor: null,
			link_type: "wikilink",
			dangling: false,
		},
	]);
	const notes = [
		{ id: "manifest-id", path: "b/My Note.md" },
		{ id: "fresh-id", path: "Fresh/Renamed Note.md" },
	];

	test("edge-map hit wins over a manifest match", () => {
		expect(wikiHref("My Note", "v", map, notes)).toBe("/v/edge-id");
	});

	test("manifest-only target links straight to the note id", () => {
		expect(wikiHref("Renamed Note", "v", map, notes)).toBe("/v/fresh-id");
	});

	test("unknown in both falls back to the wiki resolver route", () => {
		expect(wikiHref("Brand New", "v", map, notes)).toBe("/v/wiki/Brand%20New");
	});

	test("heading hash preserved on edge-map hit", () => {
		expect(wikiHref("My Note#A Heading", "v", map, notes)).toBe("/v/edge-id#a-heading");
	});

	test("heading hash preserved on manifest hit", () => {
		expect(wikiHref("Renamed Note#A Heading", "v", map, notes)).toBe("/v/fresh-id#a-heading");
	});

	test("heading hash preserved on wiki fallback", () => {
		expect(wikiHref("Brand New#A Heading", "v", map, notes)).toBe("/v/wiki/Brand%20New#a-heading");
	});
});

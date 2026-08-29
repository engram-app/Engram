import { describe, expect, test } from "vitest";
import {
	buildWikiMap,
	markdownLinkHref,
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
		expect(wikiHref("Folder/My Note", "my-vault")).toBe("/v/my-vault/wiki/Folder/My%20Note");
	});

	test("carries the heading as a slugged hash", () => {
		expect(wikiHref("Note#Some Heading", "work")).toBe("/v/work/wiki/Note#some-heading");
	});

	test("bare heading links stay on the current page", () => {
		expect(wikiHref("#Some Heading", "work")).toBe("#some-heading");
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
		expect(wikiHref("My Note", "work", map)).toBe("/v/work/n-1");
	});

	test("lookup is case-insensitive and keeps the heading hash", () => {
		expect(wikiHref("my note#Some Heading", "work", map)).toBe("/v/work/n-1#some-heading");
	});

	test("dangling target falls back to the wiki resolver route", () => {
		expect(wikiHref("Ghost", "work", map)).toBe("/v/work/wiki/Ghost");
	});

	test("target absent from the map falls back to the wiki resolver route", () => {
		expect(wikiHref("Brand New", "work", map)).toBe("/v/work/wiki/Brand%20New");
	});

	test("no map behaves exactly as before", () => {
		expect(wikiHref("My Note", "work")).toBe("/v/work/wiki/My%20Note");
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
		expect(wikiHref("My Note", "work", map, notes)).toBe("/v/work/edge-id");
	});

	test("manifest-only target links straight to the note id", () => {
		expect(wikiHref("Renamed Note", "work", map, notes)).toBe("/v/work/fresh-id");
	});

	test("unknown in both falls back to the wiki resolver route", () => {
		expect(wikiHref("Brand New", "work", map, notes)).toBe("/v/work/wiki/Brand%20New");
	});

	test("heading hash preserved on edge-map hit", () => {
		expect(wikiHref("My Note#A Heading", "work", map, notes)).toBe("/v/work/edge-id#a-heading");
	});

	test("heading hash preserved on manifest hit", () => {
		expect(wikiHref("Renamed Note#A Heading", "work", map, notes)).toBe(
			"/v/work/fresh-id#a-heading",
		);
	});

	test("heading hash preserved on wiki fallback", () => {
		expect(wikiHref("Brand New#A Heading", "work", map, notes)).toBe(
			"/v/work/wiki/Brand%20New#a-heading",
		);
	});
});

// #1302 — Obsidian writes `[label](Target.md)` when "Use [[Wikilinks]]" is
// off. The backend indexes those as note_links edges just like wikilinks, so
// the viewer resolves them through the same lookup instead of emitting a
// plain <a> that full-page-navigates to a non-route.
describe("markdownLinkHref", () => {
	const map = buildWikiMap([
		{
			target_text: "My Note.md",
			target_note_id: "n-1",
			target_attachment_id: null,
			target_path: "a/My Note.md",
			alias: "label",
			anchor: null,
			link_type: "wikilink",
			dangling: false,
		},
	]);

	const notes = [{ id: "manifest-id", path: "Other Note.md" }];

	test("resolves a vault-relative href to the note route", () => {
		expect(markdownLinkHref("My Note.md", "work", map)).toBe("/v/work/n-1");
	});

	test("decodes percent-escapes before lookup — target_text is stored decoded", () => {
		expect(markdownLinkHref("My%20Note.md", "work", map)).toBe("/v/work/n-1");
	});

	test("keeps the anchor as a slugged hash", () => {
		expect(markdownLinkHref("My%20Note.md#Some%20Heading", "work", map)).toBe(
			"/v/work/n-1#some-heading",
		);
	});

	test("falls back to the sync manifest when no edge is indexed yet", () => {
		expect(markdownLinkHref("Other Note.md", "work", map, notes)).toBe("/v/work/manifest-id");
	});

	test.each([
		["https://example.com", "external scheme"],
		["mailto:t@example.com", "mailto"],
		["//cdn.example.com/x.png", "protocol-relative"],
		["#just-a-heading", "bare anchor"],
		["/v/already-routed", "already an app route"],
		["", "empty"],
	])("%s is left alone (%s)", (href) => {
		expect(markdownLinkHref(href, "work", map, notes)).toBeNull();
	});

	test("an unresolved target stays a plain anchor, NOT the create route", () => {
		// Deliberately unlike wikilinks: a markdown link can point at an
		// attachment or a genuinely relative file, so hijacking it into the
		// note-create affordance would be wrong.
		expect(markdownLinkHref("Nope.md", "work", map, notes)).toBeNull();
	});

	test("no vault slug resolves nothing", () => {
		expect(markdownLinkHref("My Note.md", undefined, map)).toBeNull();
	});
});

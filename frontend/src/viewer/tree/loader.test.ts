import { describe, expect, it } from "vitest";
import type { AttachmentSummary, Folder, NoteSummary } from "../../api/queries";
import { buildLoader, type SortKey } from "./loader";

// The loader is a pure function of the arrays it is handed — no QueryClient, no
// network, no cache miss to fake.

const folders: Folder[] = [
	{ id: "1", parent_id: null, name: "Projects", count: 2 },
	{ id: "2", parent_id: "1", name: "Projects/Engram", count: 1 },
];

const notesByFolder: Record<string, NoteSummary[]> = {
	"1": [
		{
			id: "100",
			path: "Projects/a.md",
			title: "a",
			folder: "Projects",
			tags: [],
			version: 1,
			mtime: "2026-01-01T00:00:00Z",
			created_at: "2026-01-01T00:00:00Z",
			updated_at: "2026-01-01T00:00:00Z",
		},
	],
	"2": [
		{
			id: "200",
			path: "Projects/Engram/b.md",
			title: "b",
			folder: "Projects/Engram",
			tags: [],
			version: 1,
			mtime: "2026-01-02T00:00:00Z",
			created_at: "2026-01-02T00:00:00Z",
			updated_at: "2026-01-02T00:00:00Z",
		},
	],
};

const rootNote: NoteSummary = {
	id: "300",
	path: "top.md",
	title: "top",
	folder: "",
	tags: [],
	version: 1,
	mtime: "2026-01-03T00:00:00Z",
	created_at: "2026-01-03T00:00:00Z",
	updated_at: "2026-01-03T00:00:00Z",
};

const allNotes: NoteSummary[] = Object.values(notesByFolder).flat();

const att = (path: string): AttachmentSummary => ({
	id: `att:${path}`,
	path,
	mime_type: path.endsWith(".pdf") ? "application/pdf" : "image/png",
	size_bytes: 1,
	mtime: 0,
	updated_at: "",
});

it("lists root attachments under ROOT", () => {
	const loader = buildLoader({
		folders: [],
		notes: [],
		sort: "name-asc",
		attachments: [att("cover.png")],
	});
	const kids = loader.getChildren("root");
	const a = kids.find((k) => k.item.kind === "attachment");
	expect(a?.item).toMatchObject({ kind: "attachment", path: "cover.png", mime: "image/png" });
	expect(a?.itemId).toBe("a:cover.png");
});

it("orders root attachments by mtime under modified-desc", () => {
	const older: AttachmentSummary = { ...att("old.png"), mtime: 100 };
	const newer: AttachmentSummary = { ...att("new.png"), mtime: 200 };
	const loader = buildLoader({
		folders: [],
		notes: [],
		sort: "modified-desc",
		attachments: [older, newer],
	});
	const paths = loader
		.getChildren("root")
		.filter((k) => k.item.kind === "attachment")
		.map((k) => (k.item as { path: string }).path);
	expect(paths).toEqual(["new.png", "old.png"]);
});

it("buckets an attachment under its folder", () => {
	const folders = [{ id: "f1", parent_id: null, name: "img", count: 0 }];
	const loader = buildLoader({
		folders,
		notes: [],
		sort: "name-asc",
		attachments: [att("img/a.png")],
	});
	const kids = loader.getChildren("f:f1");
	expect(kids.map((k) => k.item.kind)).toContain("attachment");
	const a = kids.find((k) => k.item.kind === "attachment");
	expect(a?.item).toMatchObject({ path: "img/a.png" });
});

it("does not leak a subfolder attachment into its parent", () => {
	const folders = [
		{ id: "f1", parent_id: null, name: "img", count: 0 },
		{ id: "f2", parent_id: "f1", name: "img/sub", count: 0 },
	];
	const loader = buildLoader({
		folders,
		notes: [],
		sort: "name-asc",
		attachments: [att("img/sub/deep.png")],
	});
	const kids = loader.getChildren("f:f1");
	expect(kids.find((k) => k.item.kind === "attachment")).toBeUndefined();
});

it("shows attachments in a folder that holds no notes", () => {
	const folders = [{ id: "f1", parent_id: null, name: "img", count: 0 }];
	const loader = buildLoader({
		folders,
		notes: [],
		sort: "name-asc",
		attachments: [att("img/a.png")],
	});
	expect(loader.getChildren("f:f1").find((k) => k.item.kind === "attachment")).toBeDefined();
});

it("buckets an attachment under a synthetic (syn:) folder", () => {
	// The whole point of synthesizeFolders: an attachment-only dir gets a synthetic
	// folder row, and its attachment must appear as that folder's child.
	const folders = [{ id: "syn:pics", parent_id: null, name: "pics", count: 0 }];
	const loader = buildLoader({
		folders,
		notes: [],
		sort: "name-asc",
		attachments: [att("pics/a.png")],
	});
	const kids = loader.getChildren("f:syn:pics");
	const a = kids.find((k) => k.item.kind === "attachment");
	expect(a?.item).toMatchObject({ path: "pics/a.png" });
});

// A derived folder (no marker) carries a `syn:<path>` id; the loader must find
// its notes by the path that id stands for. This is where folder-id → notes
// resolution lives now that there is no per-folder query to do it.
it("buckets notes under a synthetic (syn:) folder by its path", () => {
	const folders = [{ id: "syn:Derived", parent_id: null, name: "Derived", count: 1 }];
	const loader = buildLoader({
		folders,
		notes: [{ ...rootNote, id: "d1", path: "Derived/a.md", folder: "Derived" }, rootNote],
		sort: "name-asc",
	});
	expect(loader.getChildren("f:syn:Derived").map((k) => k.itemId)).toEqual(["n:d1"]);
});

it("getItem resolves an attachment id to its row, and undefined when absent", () => {
	const loader = buildLoader({
		folders: [],
		notes: [],
		sort: "name-asc",
		attachments: [att("cover.png")],
	});
	expect(loader.getItem("a:cover.png")?.item).toMatchObject({
		kind: "attachment",
		path: "cover.png",
	});
	expect(loader.getItem("a:nope.png")).toBeUndefined();
});

describe("buildLoader", () => {
	it("root returns top-level folders then root-level notes, sorted", () => {
		const loader = buildLoader({
			folders,
			notes: [...allNotes, rootNote],
			sort: "name-asc" as SortKey,
		});
		const children = loader.getChildren("root");
		expect(children.map((c) => c.itemId)).toEqual(["f:1", "n:300"]);
	});

	it("root with no root-level notes returns folders only", () => {
		const loader = buildLoader({
			folders,
			notes: allNotes,
			sort: "name-asc" as SortKey,
		});
		const children = loader.getChildren("root");
		expect(children.map((c) => c.itemId)).toEqual(["f:1"]);
	});

	it("folder children return child folders first then notes", () => {
		const loader = buildLoader({
			folders,
			notes: allNotes,
			sort: "name-asc" as SortKey,
		});
		const children = loader.getChildren("f:1");
		expect(children.map((c) => c.itemId)).toEqual(["f:2", "n:100"]);
	});

	// There is no miss any more. The loader is handed every note in the vault,
	// so "this folder holds nothing" is an answer it can give synchronously —
	// which is what removed the lazy fetch, and with it the window where an
	// expanded folder rendered empty until a round trip came back.
	it("answers empty for a folder with no notes, without fetching", () => {
		const loader = buildLoader({
			folders: [...folders, { id: "3", parent_id: "1", name: "Projects/Empty", count: 0 }],
			notes: allNotes,
			sort: "name-asc" as SortKey,
		});
		expect(loader.getChildren("f:3")).toEqual([]);
	});

	it("getItem returns shaped TreeItem for a folder id", () => {
		const loader = buildLoader({
			folders,
			notes: allNotes,
			sort: "name-asc" as SortKey,
		});
		expect(loader.getItem("f:1")?.item).toMatchObject({
			kind: "folder",
			id: "1",
			path: "Projects",
			name: "Projects",
		});
	});

	it("note sort by modified-desc", () => {
		const loader = buildLoader({
			folders,
			notes: allNotes,
			sort: "modified-desc" as SortKey,
		});
		const children = loader.getChildren("f:1");
		// Notes only; folders sorted by name. Here just 1 note.
		expect(children.map((c) => c.itemId)).toContain("n:100");
	});
});

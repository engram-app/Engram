import { describe, expect, it, vi } from "vitest";
import * as Y from "yjs";
import { frontmatterMaps } from "./frontmatter-doc";
import { CrdtManager } from "./manager";

function freshId(): string {
	// Each test gets an isolated IndexedDB store name so fake-indexeddb state
	// never bleeds across cases.
	return `vault-${Math.random().toString(36).slice(2)}`;
}

describe("CrdtManager", () => {
	it("docId is the note_id unchanged (identity, no vault-prefix concatenation)", () => {
		const m = new CrdtManager({ onUpdate: () => {} });
		expect(m.docId("note-uuid-1")).toBe("note-uuid-1");
	});

	it("a rename does not change the CRDT doc key (docId is stable across rename)", () => {
		const m = new CrdtManager({ onUpdate: () => {} });
		const before = m.docId("note-uuid-1");
		// simulate rename: the note's path attribute changes elsewhere (tree/query
		// cache); note_id is passed to docId either way and never changes.
		const after = m.docId("note-uuid-1");
		expect(after).toBe(before);
	});

	it("forwards local edits to onUpdate, suppresses remote-origin", async () => {
		const onUpdate = vi.fn();
		const m = new CrdtManager({ onUpdate });
		// docId is now the bare note_id (no more dbPrefix namespacing in the IDB
		// key), so each test needs its own unique note id to avoid fake-indexeddb
		// state bleeding across cases (mirrors production: note_ids never collide).
		const noteId = freshId();
		const text = await m.getSharedText(noteId);

		text.insert(0, "hello"); // local origin → forwarded
		expect(onUpdate).toHaveBeenCalledTimes(1);

		// A remote update must NOT be re-forwarded.
		const other = new Y.Doc();
		other.getText("content").insert(0, "world");
		const update = Y.encodeStateAsUpdate(other);
		onUpdate.mockClear();
		await m.applyRemoteUpdate(noteId, update);
		expect(onUpdate).not.toHaveBeenCalled();
		expect((await m.getSharedText(noteId)).toJSON()).toContain("world");
	});

	it("reuses the same Y.Doc per note and tears it down on closeDoc", async () => {
		const m = new CrdtManager({ onUpdate: () => {} });
		const noteId = freshId();
		const a = await m.getDoc(noteId);
		const b = await m.getDoc(noteId);
		expect(a).toBe(b);
		m.closeDoc(noteId);
		const c = await m.getDoc(noteId);
		expect(c).not.toBe(a);
	});

	it("encodeStateVector + encodeStateAsUpdate round-trip", async () => {
		const m = new CrdtManager({ onUpdate: () => {} });
		const noteId = freshId();
		const t = await m.getSharedText(noteId);
		t.insert(0, "abc");
		const sv = await m.encodeStateVector(noteId);
		const update = await m.encodeStateAsUpdate(noteId);
		const sink = new Y.Doc();
		Y.applyUpdate(sink, update);
		expect(sink.getText("content").toJSON()).toBe("abc");
		expect(sv.length).toBeGreaterThan(0);
	});

	it("entry() awaiter resumes when the doc is destroyed mid-load (no hang)", async () => {
		// y-indexeddb never fires `synced` once destroy() runs, so a plain
		// `whenSynced`-based ready promise would hang forever. entry() must race
		// ready against a destroy signal so awaiters ALWAYS resume.
		const m = new CrdtManager({ onUpdate: () => {} });
		const p = m.getSharedText("hang.md"); // awaits entry().ready
		// Close mid-load: destroys the doc + persistence before `synced` fires.
		m.closeDoc("hang.md");
		// The awaiter must resolve within a bounded time, not hang.
		const guarded = Promise.race([
			p.then(() => "resolved" as const),
			new Promise<"timeout">((r) => setTimeout(() => r("timeout"), 500)),
		]);
		await expect(guarded).resolves.toBe("resolved");
		expect(m.hasDoc("hang.md")).toBe(false); // no ghost entry remains
	});

	it("flattenIfBloated on a non-live path is a no-op and does not create a doc", async () => {
		const m = new CrdtManager({ onUpdate: () => {} });
		await m.getDoc("notes/x.md");
		m.closeDoc("notes/x.md");
		const flattened = await m.flattenIfBloated("notes/x.md");
		expect(flattened).toBe(false);
		expect(m.hasDoc("notes/x.md")).toBe(false); // must NOT have been resurrected
	});

	// Builds a deliberately bloated Y.Doc, so this test is multi-second CPU
	// work even solo (~4s); under shared-runner contention the 30s default
	// flakes (job 87493354565: env setup alone took 368s). Timeout sized to
	// measured cost x ~20 contention, asserts untouched.
	it("flattenIfBloated preserves frontmatter maps (#814)", async () => {
		const m = new CrdtManager({ onUpdate: () => {} });
		const path = "notes/fm.md";
		const doc = await m.getDoc(path);
		const maps = frontmatterMaps(doc);
		doc.transact(() => {
			maps.values.set("type", JSON.stringify("Playbook"));
			maps.order.insert(0, ["type"]);
			maps.types.set("type", "text");
		});

		// Cross both flatten thresholds (>500 KB AND >1000 distinct client-IDs)
		// the same way the plugin's equivalent test does: apply an update
		// authored by a fresh Y.Doc per iteration so each carries a unique
		// client-ID, and pad content past the byte threshold.
		for (let i = 0; i < 1100; i++) {
			const author = new Y.Doc();
			Y.applyUpdate(author, Y.encodeStateAsUpdate(doc));
			author.getText("content").insert(author.getText("content").length, "x".repeat(500));
			Y.applyUpdate(doc, Y.encodeStateAsUpdate(author, Y.encodeStateVector(doc)));
		}

		const flattened = await m.flattenIfBloated(path);
		expect(flattened).toBe(true);

		const fresh = await m.getDoc(path);
		const after = frontmatterMaps(fresh);
		expect(after.values.get("type")).toBe(JSON.stringify("Playbook"));
		expect(after.order.toArray()).toEqual(["type"]);
		expect(after.types.get("type")).toBe("text");
	}, 90_000);
});

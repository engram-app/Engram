import { describe, expect, it, vi } from "vitest";
import * as Y from "yjs";
import { frontmatterMaps } from "./frontmatter-doc";
import { CrdtManager } from "./manager";

function freshDbName(): string {
	// Each test gets an isolated IndexedDB store name so fake-indexeddb state
	// never bleeds across cases.
	return `vault-${Math.random().toString(36).slice(2)}`;
}

describe("CrdtManager", () => {
	it("docId namespaces path under dbPrefix", () => {
		const m = new CrdtManager({ dbPrefix: "v1", onUpdate: () => {} });
		expect(m.docId("a/b.md")).toBe("v1/a/b.md");
	});

	it("forwards local edits to onUpdate, suppresses remote-origin", async () => {
		const onUpdate = vi.fn();
		const m = new CrdtManager({ dbPrefix: freshDbName(), onUpdate });
		const text = await m.getSharedText("n.md");

		text.insert(0, "hello"); // local origin → forwarded
		expect(onUpdate).toHaveBeenCalledTimes(1);

		// A remote update must NOT be re-forwarded.
		const other = new Y.Doc();
		other.getText("content").insert(0, "world");
		const update = Y.encodeStateAsUpdate(other);
		onUpdate.mockClear();
		await m.applyRemoteUpdate("n.md", update);
		expect(onUpdate).not.toHaveBeenCalled();
		expect((await m.getSharedText("n.md")).toJSON()).toContain("world");
	});

	it("reuses the same Y.Doc per path and tears it down on closeDoc", async () => {
		const m = new CrdtManager({ dbPrefix: freshDbName(), onUpdate: () => {} });
		const a = await m.getDoc("n.md");
		const b = await m.getDoc("n.md");
		expect(a).toBe(b);
		m.closeDoc("n.md");
		const c = await m.getDoc("n.md");
		expect(c).not.toBe(a);
	});

	it("encodeStateVector + encodeStateAsUpdate round-trip", async () => {
		const m = new CrdtManager({ dbPrefix: freshDbName(), onUpdate: () => {} });
		const t = await m.getSharedText("n.md");
		t.insert(0, "abc");
		const sv = await m.encodeStateVector("n.md");
		const update = await m.encodeStateAsUpdate("n.md");
		const sink = new Y.Doc();
		Y.applyUpdate(sink, update);
		expect(sink.getText("content").toJSON()).toBe("abc");
		expect(sv.length).toBeGreaterThan(0);
	});

	it("entry() awaiter resumes when the doc is destroyed mid-load (no hang)", async () => {
		// y-indexeddb never fires `synced` once destroy() runs, so a plain
		// `whenSynced`-based ready promise would hang forever. entry() must race
		// ready against a destroy signal so awaiters ALWAYS resume.
		const m = new CrdtManager({ dbPrefix: freshDbName(), onUpdate: () => {} });
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
		const m = new CrdtManager({ dbPrefix: freshDbName(), onUpdate: () => {} });
		await m.getDoc("notes/x.md");
		m.closeDoc("notes/x.md");
		const flattened = await m.flattenIfBloated("notes/x.md");
		expect(flattened).toBe(false);
		expect(m.hasDoc("notes/x.md")).toBe(false); // must NOT have been resurrected
	});

	it("flattenIfBloated preserves frontmatter maps (#814)", async () => {
		const m = new CrdtManager({ dbPrefix: freshDbName(), onUpdate: () => {} });
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
	}, 30_000);
});

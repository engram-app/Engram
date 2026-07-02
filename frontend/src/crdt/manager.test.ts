import { describe, expect, it, vi } from "vitest";
import * as Y from "yjs";
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

	it("flattenIfBloated on a non-live path is a no-op and does not create a doc", async () => {
		const m = new CrdtManager({ dbPrefix: freshDbName(), onUpdate: () => {} });
		await m.getDoc("notes/x.md");
		m.closeDoc("notes/x.md");
		const flattened = await m.flattenIfBloated("notes/x.md");
		expect(flattened).toBe(false);
		expect(m.hasDoc("notes/x.md")).toBe(false); // must NOT have been resurrected
	});
});

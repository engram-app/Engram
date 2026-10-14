import { describe, expect, test } from "vitest";
import * as Y from "yjs";
import { addKey, frontmatterMaps, rawMap, removeKey, setValue } from "./frontmatter-doc";
import { undoKeyHandler, undoManagerFor } from "./undo";

// No capture window, so every transaction is its own undo step.
function fresh() {
	const doc = new Y.Doc();
	const um = undoManagerFor(doc);
	um.captureTimeout = 0;
	return { doc, um, text: doc.getText("content") };
}

describe("undoManagerFor", () => {
	test("one manager per doc", () => {
		const doc = new Y.Doc();
		expect(undoManagerFor(doc)).toBe(undoManagerFor(doc));
		expect(undoManagerFor(new Y.Doc())).not.toBe(undoManagerFor(doc));
	});

	test("undoes a property value change", () => {
		const { doc, um } = fresh();
		addKey(doc, "status", "text");
		setValue(doc, "status", "draft");
		setValue(doc, "status", "done");
		um.undo();
		expect(frontmatterMaps(doc).values.get("status")).toBe(JSON.stringify("draft"));
		um.redo();
		expect(frontmatterMaps(doc).values.get("status")).toBe(JSON.stringify("done"));
	});

	test("undoes a removed property, order included", () => {
		const { doc, um } = fresh();
		addKey(doc, "a", "text");
		addKey(doc, "b", "text");
		removeKey(doc, "a");
		um.undo();
		expect(frontmatterMaps(doc).order.toArray()).toEqual(["a", "b"]);
	});

	test("body and frontmatter share one stack, in edit order", () => {
		const { doc, um, text } = fresh();
		text.insert(0, "hello");
		addKey(doc, "tags", "list");
		text.insert(5, " world");
		um.undo();
		expect(text.toString()).toBe("hello");
		expect(frontmatterMaps(doc).values.has("tags")).toBe(true);
		um.undo();
		expect(frontmatterMaps(doc).values.has("tags")).toBe(false);
		um.undo();
		expect(text.toString()).toBe("");
	});

	test("covers the raw (degraded) frontmatter map", () => {
		const { doc, um } = fresh();
		doc.transact(() => rawMap(doc).set("weird", "a: [b"));
		um.undo();
		expect(rawMap(doc).has("weird")).toBe(false);
	});

	test("never undoes a remote peer's edit", () => {
		const { doc, um } = fresh();
		const peer = new Y.Doc();
		addKey(peer, "remote", "text");
		Y.applyUpdate(doc, Y.encodeStateAsUpdate(peer), "remote-origin");
		expect(um.undoStack).toHaveLength(0);
		um.undo();
		expect(frontmatterMaps(doc).values.has("remote")).toBe(true);
	});
});

describe("undoKeyHandler", () => {
	function press(target: Element, init: KeyboardEventInit) {
		const e = new KeyboardEvent("keydown", { bubbles: true, cancelable: true, ...init });
		target.dispatchEvent(e);
		return e;
	}

	function setup(markup: string) {
		const { doc, um } = fresh();
		addKey(doc, "tags", "list");
		document.body.innerHTML = markup;
		const handler = undoKeyHandler(doc);
		document.addEventListener("keydown", handler);
		return { doc, um, cleanup: () => document.removeEventListener("keydown", handler) };
	}

	test("Ctrl+Z on a non-text control undoes, Ctrl+Shift+Z and Ctrl+Y redo", () => {
		const { doc, cleanup } = setup("<button>x</button>");
		const btn = document.querySelector("button") as Element;
		expect(press(btn, { key: "z", ctrlKey: true }).defaultPrevented).toBe(true);
		expect(frontmatterMaps(doc).values.has("tags")).toBe(false);
		press(btn, { key: "z", ctrlKey: true, shiftKey: true });
		expect(frontmatterMaps(doc).values.has("tags")).toBe(true);
		press(btn, { key: "z", metaKey: true });
		press(btn, { key: "y", ctrlKey: true });
		expect(frontmatterMaps(doc).values.has("tags")).toBe(true);
		cleanup();
	});

	test("Ctrl+Z on the page body undoes", () => {
		const { doc, cleanup } = setup("");
		press(document.body, { key: "Z", ctrlKey: true });
		expect(frontmatterMaps(doc).values.has("tags")).toBe(false);
		cleanup();
	});

	test.each([
		["text input", '<input type="text" />'],
		["textarea", "<textarea></textarea>"],
		["contenteditable", '<div contenteditable="true"></div>'],
	])("leaves %s to its own undo", (_name, markup) => {
		const { doc, cleanup } = setup(markup);
		const el = document.body.firstElementChild as Element;
		expect(press(el, { key: "z", ctrlKey: true }).defaultPrevented).toBe(false);
		expect(frontmatterMaps(doc).values.has("tags")).toBe(true);
		cleanup();
	});

	test("ignores an event something already handled", () => {
		const { doc, cleanup } = setup("<button>x</button>");
		const btn = document.querySelector("button") as Element;
		btn.addEventListener("keydown", (e) => e.preventDefault());
		press(btn, { key: "z", ctrlKey: true });
		expect(frontmatterMaps(doc).values.has("tags")).toBe(true);
		cleanup();
	});

	test("plain z does nothing", () => {
		const { doc, cleanup } = setup("<button>x</button>");
		press(document.querySelector("button") as Element, { key: "z" });
		expect(frontmatterMaps(doc).values.has("tags")).toBe(true);
		cleanup();
	});
});

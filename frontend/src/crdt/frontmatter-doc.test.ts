import { describe, expect, test } from "vitest";
import * as Y from "yjs";
import {
	addKey,
	FRONTMATTER_KEY,
	frontmatterMaps,
	moveKey,
	ORDER_KEY,
	readRows,
	removeKey,
	setType,
	setValue,
	TYPES_KEY,
} from "./frontmatter-doc";

function seed(doc: Y.Doc) {
	doc.transact(() => {
		const v = doc.getMap<string>(FRONTMATTER_KEY);
		v.set("title", JSON.stringify("Hi"));
		v.set("tags", JSON.stringify(["a", "b"]));
		doc.getArray<string>(ORDER_KEY).insert(0, ["title", "tags"]);
		doc.getMap<string>(TYPES_KEY).set("title", "text");
	});
}

describe("frontmatter-doc", () => {
	test("frontmatterMaps returns the three shared types by name", () => {
		const doc = new Y.Doc();
		const m = frontmatterMaps(doc);
		expect(m.values).toBe(doc.getMap(FRONTMATTER_KEY));
		expect(m.order).toBe(doc.getArray(ORDER_KEY));
		expect(m.types).toBe(doc.getMap(TYPES_KEY));
	});

	test("readRows decodes values in order with type overrides", () => {
		const doc = new Y.Doc();
		seed(doc);
		expect(readRows(doc)).toEqual([
			{ key: "title", value: "Hi", typeOverride: "text" },
			{ key: "tags", value: ["a", "b"], typeOverride: null },
		]);
	});

	test("readRows keeps the raw string when a value is not valid JSON", () => {
		const doc = new Y.Doc();
		doc.transact(() => {
			doc.getMap<string>(FRONTMATTER_KEY).set("broken", "not json{");
			doc.getArray<string>(ORDER_KEY).insert(0, ["broken"]);
		});
		expect(readRows(doc)).toEqual([{ key: "broken", value: "not json{", typeOverride: null }]);
	});

	test("empty doc yields no rows", () => {
		expect(readRows(new Y.Doc())).toEqual([]);
	});
});

describe("frontmatter-doc mutations", () => {
	test("setValue writes only when changed", () => {
		const doc = new Y.Doc();
		addKey(doc, "title", "text");
		setValue(doc, "title", "Hello");
		expect(readRows(doc)).toEqual([{ key: "title", value: "Hello", typeOverride: "text" }]);
	});

	test("addKey rejects empty and duplicate", () => {
		const doc = new Y.Doc();
		expect(addKey(doc, "a", "text")).toBe(true);
		expect(addKey(doc, "a", "text")).toBe(false);
		expect(addKey(doc, "", "text")).toBe(false);
		expect(readRows(doc).map((r) => r.key)).toEqual(["a"]);
	});

	test("addKey seeds a typed empty default", () => {
		const doc = new Y.Doc();
		addKey(doc, "tags", "list");
		addKey(doc, "done", "checkbox");
		expect(readRows(doc)).toEqual([
			{ key: "tags", value: [], typeOverride: "list" },
			{ key: "done", value: false, typeOverride: "checkbox" },
		]);
	});

	test("removeKey drops from all three maps", () => {
		const doc = new Y.Doc();
		addKey(doc, "a", "text");
		addKey(doc, "b", "text");
		removeKey(doc, "a");
		expect(readRows(doc).map((r) => r.key)).toEqual(["b"]);
	});

	test("moveKey swaps neighbors and no-ops at ends", () => {
		const doc = new Y.Doc();
		addKey(doc, "a", "text");
		addKey(doc, "b", "text");
		moveKey(doc, "b", "up");
		expect(readRows(doc).map((r) => r.key)).toEqual(["b", "a"]);
		moveKey(doc, "b", "up");
		expect(readRows(doc).map((r) => r.key)).toEqual(["b", "a"]);
	});

	test("setType coerces the stored value", () => {
		const doc = new Y.Doc();
		addKey(doc, "x", "text");
		setValue(doc, "x", "hi");
		setType(doc, "x", "list");
		expect(readRows(doc)).toEqual([{ key: "x", value: ["hi"], typeOverride: "list" }]);
	});
});

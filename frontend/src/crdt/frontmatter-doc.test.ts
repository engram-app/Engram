import { describe, expect, test } from "vitest";
import * as Y from "yjs";
import {
	addKey,
	applyParsedFrontmatter,
	emitFrontmatterText,
	FRONTMATTER_KEY,
	frontmatterMaps,
	moveKey,
	ORDER_KEY,
	type PropertyRow,
	rawMap,
	readRaws,
	readRows,
	removeKey,
	renameKey,
	setType,
	setValue,
	sortRowsOkfFirst,
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

	test("renameKey keeps the value, the type and the position", () => {
		const doc = new Y.Doc();
		addKey(doc, "a", "text");
		addKey(doc, "status", "list");
		addKey(doc, "z", "text");
		setValue(doc, "status", ["draft"]);

		expect(renameKey(doc, "status", "state")).toBe(true);

		const rows = readRows(doc);
		// Renaming is not remove-then-add: it must not fall to the end.
		expect(rows.map((r) => r.key)).toEqual(["a", "state", "z"]);
		const renamed = rows.find((r) => r.key === "state");
		expect(renamed?.value).toEqual(["draft"]);
		expect(renamed?.typeOverride).toBe("list");
	});

	// A degraded key lives in `order` + the raw map and deliberately NOT in
	// `values`, so a collision check that only consults `values` waves it
	// through: `order` ends up with the name twice, the raw wins in
	// emitFrontmatter, and the renamed property's value is gone from the note.
	test("renameKey refuses a name held by a degraded key", () => {
		const doc = new Y.Doc();
		addKey(doc, "good", "text");
		setValue(doc, "good", "keepme");
		rawMap(doc).set("weird", "weird: !!binary |\n  Zm9v\n");
		frontmatterMaps(doc).order.push(["weird"]);

		expect(renameKey(doc, "good", "weird")).toBe(false);
		expect(frontmatterMaps(doc).order.toArray()).toEqual(["good", "weird"]);
		expect(readRows(doc).find((r) => r.key === "good")?.value).toBe("keepme");
	});

	test("addKey refuses a name held by a degraded key", () => {
		const doc = new Y.Doc();
		rawMap(doc).set("weird", "weird: !!binary |\n  Zm9v\n");
		frontmatterMaps(doc).order.push(["weird"]);

		expect(addKey(doc, "weird", "text")).toBe(false);
		expect(frontmatterMaps(doc).order.toArray()).toEqual(["weird"]);
	});

	test("renameKey refuses an empty, unchanged or colliding name", () => {
		const doc = new Y.Doc();
		addKey(doc, "a", "text");
		addKey(doc, "b", "text");
		expect(renameKey(doc, "a", "   ")).toBe(false);
		expect(renameKey(doc, "a", "b")).toBe(false);
		expect(renameKey(doc, "a", "a")).toBe(false);
		expect(readRows(doc).map((r) => r.key)).toEqual(["a", "b"]);
	});

	test("renameKey trims, so a stray space cannot mint a second property", () => {
		const doc = new Y.Doc();
		addKey(doc, "a", "text");
		expect(renameKey(doc, "a", "  b  ")).toBe(true);
		expect(readRows(doc).map((r) => r.key)).toEqual(["b"]);
	});

	test("setType coerces the stored value", () => {
		const doc = new Y.Doc();
		addKey(doc, "x", "text");
		setValue(doc, "x", "hi");
		setType(doc, "x", "list");
		expect(readRows(doc)).toEqual([{ key: "x", value: ["hi"], typeOverride: "list" }]);
	});
});

describe("sortRowsOkfFirst", () => {
	const row = (key: string): PropertyRow => ({ key, value: "x", typeOverride: null });

	test("pins OKF keys in spec order before custom keys", () => {
		const rows = ["zeta", "tags", "alpha", "type", "created"].map(row);
		expect(sortRowsOkfFirst(rows).map((r) => r.key)).toEqual([
			"type",
			"created",
			"tags",
			"zeta",
			"alpha",
		]);
	});

	test("is stable for custom keys and identity when no OKF keys present", () => {
		const rows = ["b", "a", "c"].map(row);
		expect(sortRowsOkfFirst(rows).map((r) => r.key)).toEqual(["b", "a", "c"]);
	});
});

describe("frontmatter apply-diff", () => {
	test("upserts changed keys and preserves untouched keys (no clobber)", () => {
		const doc = new Y.Doc();
		seed(doc); // title="Hi", tags=["a","b"]
		const { values } = frontmatterMaps(doc);
		const touched: string[] = [];
		values.observe((e) => {
			for (const k of e.keys.keys()) {
				touched.push(k);
			}
		});
		applyParsedFrontmatter(doc, {
			order: ["title", "tags"],
			values: { title: JSON.stringify("Bye"), tags: JSON.stringify(["a", "b"]) },
		});
		expect(readRows(doc)).toEqual([
			{ key: "title", value: "Bye", typeOverride: "text" },
			{ key: "tags", value: ["a", "b"], typeOverride: null },
		]);
		// The real proof: tags never got re-written even though it was re-submitted
		// unchanged. A wholesale values.clear()+re-set would touch both keys and
		// fail this assertion.
		expect(touched).toContain("title");
		expect(touched).not.toContain("tags");
	});

	test("deletes keys removed from the text unless preserved as raw", () => {
		const doc = new Y.Doc();
		seed(doc);
		// "keepme" lives in BOTH the live values/order maps AND frontmatter_raw, so
		// the delete loop actually iterates it and must consult the `!raws.has(key)`
		// guard to skip deleting it. (A "keepme" that only ever existed in raws,
		// never in values, never exercises the guard at all.)
		const { values, order } = frontmatterMaps(doc);
		values.set("keepme", JSON.stringify("v"));
		order.push(["keepme"]);
		rawMap(doc).set("keepme", "keepme: v\n");
		applyParsedFrontmatter(doc, { order: ["title"], values: { title: JSON.stringify("Hi") } });
		const keys = readRows(doc).map((r) => r.key);
		expect(keys).toContain("title");
		expect(keys).not.toContain("tags"); // removed, no raw to preserve it
		// "keepme" drops out of `order` (order is wholesale-replaced to match
		// parsed.order), but the `!raws.has(key)` guard must stop it from being
		// deleted out of the live `values` map. Without the guard this is false.
		expect(values.has("keepme")).toBe(true);
		expect(readRaws(doc)).toHaveProperty("keepme");
	});

	test("does not double-encode: applied values are canonical JSON strings", () => {
		const doc = new Y.Doc();
		applyParsedFrontmatter(doc, { order: ["n"], values: { n: JSON.stringify(3) } });
		expect(readRows(doc)).toEqual([{ key: "n", value: 3, typeOverride: null }]);
	});

	test("emitFrontmatterText renders live values verbatim, and raw spans verbatim over the live value", () => {
		const doc = new Y.Doc();
		seed(doc);
		expect(emitFrontmatterText(doc)).toContain("title:");
		expect(emitFrontmatterText(doc)).toContain("tags:");

		// A key with BOTH a live value and a raw span renders the raw text
		// verbatim (preserving unparseable/exotic YAML), not the re-encoded value.
		const { values, order } = frontmatterMaps(doc);
		values.set("weird", JSON.stringify("!!binary abc"));
		order.push(["weird"]);
		rawMap(doc).set("weird", "weird: !!binary abc\n");
		expect(emitFrontmatterText(doc)).toContain("weird: !!binary abc");
	});
});

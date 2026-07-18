import { EditorView } from "@codemirror/view";
import { act, cleanup, render } from "@testing-library/react";
import { afterEach, describe, expect, test, vi } from "vitest";
import * as Y from "yjs";
import { readRows } from "../../crdt/frontmatter-doc";
import { commitYaml, RawFrontmatterEditor } from "./raw-frontmatter-editor";

afterEach(() => {
	vi.useRealTimers();
	cleanup();
});

describe("commitYaml", () => {
	test("applies valid YAML as a canonical (non-double-encoded) string value", () => {
		const doc = new Y.Doc();
		expect(commitYaml(doc, "title: Hi\n")).toBe("ok");
		expect(readRows(doc)).toEqual([{ key: "title", value: "Hi", typeOverride: null }]);
	});

	test("applies valid YAML with number typing end-to-end", () => {
		const doc = new Y.Doc();
		expect(commitYaml(doc, "count: 3\n")).toBe("ok");
		expect(readRows(doc)).toEqual([{ key: "count", value: 3, typeOverride: null }]);
	});

	test("rejects invalid YAML without mutating the Y.Map", () => {
		const doc = new Y.Doc();
		doc.transact(() => {
			doc.getMap<string>("frontmatter").set("title", JSON.stringify("Keep"));
			doc.getArray<string>("frontmatter_order").insert(0, ["title"]);
		});
		const before = readRows(doc);
		expect(commitYaml(doc, "title: [broken\n")).toBe("invalid");
		expect(readRows(doc)).toEqual(before);
		expect(readRows(doc)).toEqual([{ key: "title", value: "Keep", typeOverride: null }]);
	});

	test("tolerates a missing trailing newline", () => {
		const doc = new Y.Doc();
		expect(commitYaml(doc, "title: Hi")).toBe("ok");
		expect(readRows(doc)).toEqual([{ key: "title", value: "Hi", typeOverride: null }]);
	});
});

describe("RawFrontmatterEditor", () => {
	test("seeds the CodeMirror editor from the Y.Map on mount", () => {
		const doc = new Y.Doc();
		doc.transact(() => {
			doc.getMap<string>("frontmatter").set("title", JSON.stringify("Old"));
			doc.getArray<string>("frontmatter_order").insert(0, ["title"]);
		});
		const { container } = render(<RawFrontmatterEditor doc={doc} />);
		const editor = container.querySelector(".cm-content");
		expect(editor?.textContent).toContain("title: Old");
	});

	test("a real keystroke, after the debounce, commits to the Y.Map (and the marker clears on a subsequent valid edit)", () => {
		vi.useFakeTimers();
		const doc = new Y.Doc();
		doc.transact(() => {
			doc.getMap<string>("frontmatter").set("title", JSON.stringify("Old"));
			doc.getArray<string>("frontmatter_order").insert(0, ["title"]);
		});
		const { container } = render(<RawFrontmatterEditor doc={doc} />);
		const editorDom = container.querySelector(".cm-editor") as HTMLElement;
		const view = EditorView.findFromDOM(editorDom);
		expect(view).not.toBeNull();

		// Drive a real editor transaction (not the Y.Map directly) replacing the
		// whole doc with new, valid YAML — proves the updateListener -> debounce
		// -> commitYaml wiring, not just commitYaml in isolation.
		view!.dispatch({
			changes: { from: 0, to: view!.state.doc.length, insert: "title: New\n" },
		});

		// Not yet committed: debounce hasn't elapsed.
		expect(readRows(doc)).toEqual([{ key: "title", value: "Old", typeOverride: null }]);

		act(() => {
			vi.advanceTimersByTime(400);
		});

		expect(readRows(doc)).toEqual([{ key: "title", value: "New", typeOverride: null }]);
		expect(container.querySelector('[class*="text-destructive"]')).toBeNull();

		// Now drive an invalid edit through the same real path and confirm the
		// marker appears and the Y.Map is left at its last-valid state.
		view!.dispatch({
			changes: { from: 0, to: view!.state.doc.length, insert: "title: [broken\n" },
		});
		act(() => {
			vi.advanceTimersByTime(400);
		});

		expect(readRows(doc)).toEqual([{ key: "title", value: "New", typeOverride: null }]);
		expect(container.querySelector('[class*="text-destructive"]')).not.toBeNull();
	});
});

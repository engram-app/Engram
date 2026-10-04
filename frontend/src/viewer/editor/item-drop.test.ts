import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, expect, test, vi } from "vitest";
import { setDraggedItem } from "../vault-item-drag";
import { itemDrop } from "./item-drop";

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc: string) {
	view = new EditorView({
		state: EditorState.create({
			doc,
			extensions: [itemDrop({ linkText: (i) => (i.kind === "note" ? "[[N]]" : "![[a.png]]") })],
		}),
		parent: document.body,
	});
	// happy-dom has no layout; place every drop at the end of the doc.
	view.posAtCoords = () => view.state.doc.length;
}

function dropEvent(setup?: (dt: DataTransfer) => void) {
	const store = new Map<string, string>();
	const dt = {
		get types() {
			return [...store.keys()];
		},
		setData: (t: string, v: string) => {
			store.set(t, v);
		},
		getData: (t: string) => store.get(t) ?? "",
		dropEffect: "none",
	} as unknown as DataTransfer;
	setup?.(dt);
	const e = new Event("drop", { bubbles: true, cancelable: true }) as DragEvent;
	Object.assign(e, { dataTransfer: dt, clientX: 1, clientY: 1 });
	return e;
}

test("dropping a sidebar attachment inserts its embed at the drop point", () => {
	mount("hello ");
	const e = dropEvent((dt) => setDraggedItem(dt, { kind: "attachment", path: "a.png" }));
	view.contentDOM.dispatchEvent(e);
	expect(view.state.doc.toString()).toBe("hello ![[a.png]]");
	expect(e.defaultPrevented).toBe(true);
});

test("dropping a note inserts a wikilink", () => {
	mount("see ");
	view.contentDOM.dispatchEvent(
		dropEvent((dt) => setDraggedItem(dt, { kind: "note", path: "N.md" })),
	);
	expect(view.state.doc.toString()).toBe("see [[N]]");
});

test("leaves any other drop to the editor", () => {
	mount("x");
	const e = dropEvent();
	view.contentDOM.dispatchEvent(e);
	expect(view.state.doc.toString()).toBe("x");
});

test("accepts a vault-item dragover so the drop can fire", () => {
	mount("x");
	const e = dropEvent((dt) => setDraggedItem(dt, { kind: "note", path: "N.md" }));
	const over = new Event("dragover", { bubbles: true, cancelable: true }) as DragEvent;
	Object.assign(over, { dataTransfer: e.dataTransfer });
	view.contentDOM.dispatchEvent(over);
	expect(over.defaultPrevented).toBe(true);
});

test("dropping OS files hands them to onFiles and inserts the embeds it returns", async () => {
	const onFiles = vi.fn((_files: File[]) => Promise.resolve(["![[up.png]]"]));
	view = new EditorView({
		state: EditorState.create({
			doc: "hi ",
			extensions: [itemDrop({ linkText: () => "", onFiles })],
		}),
		parent: document.body,
	});
	view.posAtCoords = () => view.state.doc.length;
	const file = new File(["x"], "up.png", { type: "image/png" });
	const e = new Event("drop", { bubbles: true, cancelable: true }) as DragEvent;
	Object.assign(e, {
		dataTransfer: { types: ["Files"], files: [file], getData: () => "" },
		clientX: 1,
		clientY: 1,
	});
	view.contentDOM.dispatchEvent(e);
	expect(e.defaultPrevented).toBe(true);
	expect(onFiles).toHaveBeenCalledWith([file]);
	await vi.waitFor(() => expect(view.state.doc.toString()).toBe("hi ![[up.png]]"));
});

test("accepts a Files dragover when file drops are enabled", () => {
	view = new EditorView({
		state: EditorState.create({
			doc: "x",
			extensions: [itemDrop({ linkText: () => "", onFiles: () => Promise.resolve([]) })],
		}),
		parent: document.body,
	});
	const over = new Event("dragover", { bubbles: true, cancelable: true }) as DragEvent;
	Object.assign(over, { dataTransfer: { types: ["Files"], files: [] } });
	view.contentDOM.dispatchEvent(over);
	expect(over.defaultPrevented).toBe(true);
});

test("shows a drop cursor that follows the pointer while a file or item is dragged over", () => {
	view = new EditorView({
		state: EditorState.create({
			doc: "hello",
			extensions: [itemDrop({ linkText: () => "", onFiles: () => Promise.resolve([]) })],
		}),
		parent: document.body,
	});
	view.posAtCoords = () => 2;
	const over = new Event("dragover", { bubbles: true, cancelable: true }) as DragEvent;
	Object.assign(over, { dataTransfer: { types: ["Files"], files: [] }, clientX: 1, clientY: 1 });
	view.contentDOM.dispatchEvent(over);
	expect(view.dom.querySelector(".cm-dropCursor")).not.toBeNull();
});

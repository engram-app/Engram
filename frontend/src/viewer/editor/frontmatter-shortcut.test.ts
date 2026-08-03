import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, it, vi } from "vitest";
import { frontmatterShortcut } from "./frontmatter-shortcut";

let view: EditorView | null = null;

afterEach(() => {
	view?.destroy();
	view = null;
});

const mount = (doc: string, onTrigger: () => boolean) => {
	view = new EditorView({
		state: EditorState.create({ doc, extensions: [frontmatterShortcut(onTrigger)] }),
		parent: document.body,
	});
	return view;
};

// The fence is removed from a queued microtask — dispatching inside an
// update listener is illegal in CodeMirror.
const settle = () => Promise.resolve();

const edit = (v: EditorView, from: number, insert: string, userEvent = "input.type") => {
	v.dispatch({ changes: { from, insert }, userEvent });
};

describe("frontmatterShortcut", () => {
	it("consumes a --- typed on the first line", async () => {
		const onTrigger = vi.fn(() => true);
		const v = mount("--", onTrigger);
		edit(v, 2, "-");
		await settle();
		expect(onTrigger).toHaveBeenCalled();
		expect(v.state.doc.toString()).toBe("");
	});

	it("takes the newline with it, leaving the body untouched", async () => {
		const v = mount("--\nbody", () => true);
		edit(v, 2, "-");
		await settle();
		expect(v.state.doc.toString()).toBe("body");
	});

	// The caller declines when the note already has frontmatter, and then the
	// fence has to survive as an ordinary horizontal rule.
	it("leaves the fence alone when the caller declines", async () => {
		const onTrigger = vi.fn(() => false);
		const v = mount("--", onTrigger);
		edit(v, 2, "-");
		await settle();
		expect(onTrigger).toHaveBeenCalled();
		expect(v.state.doc.toString()).toBe("---");
	});

	it("ignores a fence on any line but the first", async () => {
		const onTrigger = vi.fn(() => true);
		const v = mount("body\n--", onTrigger);
		edit(v, 7, "-");
		await settle();
		expect(onTrigger).not.toHaveBeenCalled();
		expect(v.state.doc.toString()).toBe("body\n---");
	});

	// The guard that matters most: a note whose body legitimately opens with a
	// horizontal rule must not lose it the moment you type anywhere else.
	it("ignores edits elsewhere in a document that already starts with ---", async () => {
		const onTrigger = vi.fn(() => true);
		const v = mount("---\nbody", onTrigger);
		edit(v, 8, "!");
		await settle();
		expect(onTrigger).not.toHaveBeenCalled();
		expect(v.state.doc.toString()).toBe("---\nbody!");
	});

	it("ignores pasted text", async () => {
		const onTrigger = vi.fn(() => true);
		const v = mount("", onTrigger);
		edit(v, 0, "---", "input.paste");
		await settle();
		expect(onTrigger).not.toHaveBeenCalled();
		expect(v.state.doc.toString()).toBe("---");
	});

	// Undo restores the fence. Re-firing there would delete it again and the
	// two would fight forever.
	it("ignores an undo that restores the fence", async () => {
		const onTrigger = vi.fn(() => true);
		const v = mount("", onTrigger);
		edit(v, 0, "---", "undo");
		await settle();
		expect(onTrigger).not.toHaveBeenCalled();
		expect(v.state.doc.toString()).toBe("---");
	});
});

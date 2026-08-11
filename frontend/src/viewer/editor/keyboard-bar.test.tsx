import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { yCollab } from "y-codemirror.next";
import * as Y from "yjs";
import { KeyboardBar } from "./keyboard-bar";

const { insetValue } = vi.hoisted(() => ({ insetValue: { current: 300 } }));
vi.mock("./use-keyboard-inset", () => ({ useKeyboardInset: () => insetValue.current }));

// History lives in Yjs, not CodeMirror, and the failure mode is a DEAD button
// rather than a crash — so these tests run a real yCollab with a real
// Y.UndoManager instead of stubbing one. A stub would have happily passed
// while the buttons drove the wrong manager, which is exactly the bug this
// caught: YSyncConfig mints its own decoy UndoManager that nothing tracks.
let ydoc: Y.Doc;

let view: EditorView;
afterEach(() => {
	view?.destroy();
	ydoc?.destroy();
});

// The bar is gated on editor focus, so the harness has to focus for real —
// creating a view is not enough.
function mountEditor(doc: string, at = 0) {
	// Seed the Y.Text first: ySync drives the view from the Y doc, so a view
	// created with content the Y.Text lacks is immediately emptied.
	ydoc = new Y.Doc();
	const ytext = ydoc.getText("content");
	ytext.insert(0, doc);
	view = new EditorView({
		state: EditorState.create({
			doc: ytext.toString(),
			selection: { anchor: at, head: at },
			extensions: [yCollab(ytext, null)],
		}),
		parent: document.body,
	});
	view.focus();
	return view;
}

function mount(doc: string, at = 0) {
	mountEditor(doc, at);
	return render(<KeyboardBar getView={() => view} />);
}

function setViewport(kind: "desktop" | "mobile") {
	window.matchMedia = vi.fn().mockReturnValue({
		matches: kind === "desktop",
		addEventListener: vi.fn(),
		removeEventListener: vi.fn(),
	}) as unknown as typeof window.matchMedia;
}

beforeEach(() => {
	setViewport("mobile");
	insetValue.current = 300;
});

describe("KeyboardBar", () => {
	it("is absent on desktop, where Tab and the markdown shortcuts already cover this", () => {
		setViewport("desktop");
		mount("hello");
		expect(screen.queryByRole("toolbar", { name: "Editor actions" })).toBeNull();
	});

	// Pinned to the bottom with no keyboard under it, the bar is just lost height.
	it("is absent while the editor is unfocused", () => {
		render(<KeyboardBar getView={() => null} />);
		expect(screen.queryByRole("toolbar", { name: "Editor actions" })).toBeNull();
	});

	// The bug that made the bar never appear on a real phone. Browsers that
	// resize the LAYOUT viewport for the keyboard (older Chrome, or
	// interactive-widget=resizes-content) drop window.innerHeight by the same
	// amount the visual viewport lost, so the inset reads 0 with the keyboard
	// fully open. Gating visibility on a non-zero inset hid the bar outright on
	// exactly those browsers; focus is the portable signal.
	it("shows with the keyboard up even when the inset reads 0", () => {
		insetValue.current = 0;
		mount("hello");
		const bar = screen.getByRole("toolbar", { name: "Editor actions" });
		expect(bar).toBeInTheDocument();
		// bottom-0 with no lift is already correct there: the viewport shrank.
		expect(bar.style.transform).toBe("translateY(-0px)");
	});

	it("rides above the keyboard by the measured inset", () => {
		mount("hello");
		const bar = screen.getByRole("toolbar", { name: "Editor actions" });
		expect(bar.style.transform).toBe("translateY(-300px)");
	});

	// The whole feature collapses if a tap dismisses the keyboard: iOS blurs the
	// editor, the inset drops to 0, and the bar unmounts from under the finger.
	it("does not let a press move focus off the editor", () => {
		mount("hello");
		const bar = screen.getByRole("toolbar", { name: "Editor actions" });
		const evt = new PointerEvent("pointerdown", { bubbles: true, cancelable: true });
		fireEvent(bar, evt);
		expect(evt.defaultPrevented).toBe(true);
	});

	it("indents the caret line", () => {
		mount("item");
		fireEvent.click(screen.getByRole("button", { name: "Indent" }));
		expect(view.state.doc.toString()).not.toBe("item");
		expect(view.state.doc.toString().trimStart()).toBe("item");
	});

	it("outdents an indented line back", () => {
		mount("\t\titem", 2);
		fireEvent.click(screen.getByRole("button", { name: "Outdent" }));
		expect(view.state.doc.toString().startsWith("\t\t")).toBe(false);
	});

	it("toggles a checkbox onto the caret line", () => {
		mount("buy milk");
		fireEvent.click(screen.getByRole("button", { name: "Toggle checkbox" }));
		expect(view.state.doc.toString()).toBe("- [ ] buy milk");
	});

	it("undoes a toolbar edit through the Yjs history", () => {
		mount("hello");
		fireEvent.click(screen.getByRole("button", { name: "Bullet list" }));
		expect(view.state.doc.toString()).toBe("- hello");

		fireEvent.click(screen.getByRole("button", { name: "Undo" }));
		expect(view.state.doc.toString()).toBe("hello");
	});

	it("redoes what it undid", () => {
		mount("hello");
		fireEvent.click(screen.getByRole("button", { name: "Bullet list" }));
		fireEvent.click(screen.getByRole("button", { name: "Undo" }));
		expect(view.state.doc.toString()).toBe("hello");

		fireEvent.click(screen.getByRole("button", { name: "Redo" }));
		expect(view.state.doc.toString()).toBe("- hello");
	});

	it("turns the caret line into a bullet", () => {
		mount("thing");
		fireEvent.click(screen.getByRole("button", { name: "Bullet list" }));
		expect(view.state.doc.toString()).toBe("- thing");
	});

	// getView can return null between a route swap and the next editor mounting,
	// while focus is still inside the outgoing one.
	it("does nothing when the view accessor returns null", () => {
		mountEditor("hello");
		render(<KeyboardBar getView={() => null} />);
		fireEvent.click(screen.getByRole("button", { name: "Indent" }));
		expect(screen.getByRole("toolbar", { name: "Editor actions" })).toBeInTheDocument();
	});
});

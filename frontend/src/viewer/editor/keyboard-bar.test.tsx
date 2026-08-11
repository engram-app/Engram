import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { yCollab } from "y-codemirror.next";
import * as Y from "yjs";
import { KeyboardBar } from "./keyboard-bar";

const { insetValue, keyboardOpen } = vi.hoisted(() => ({
	insetValue: { current: 300 },
	keyboardOpen: { current: true },
}));
vi.mock("./use-keyboard-inset", () => ({
	useKeyboardInset: () => insetValue.current,
	useKeyboardOpen: () => keyboardOpen.current,
}));

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
			// The markdown grammar is not decoration here: toggleWrap asks the
			// parser whether the selection is already emphasised, so without it the
			// emphasis buttons only ever wrap and never toggle off.
			extensions: [yCollab(ytext, null), markdown({ base: markdownLanguage })],
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
	keyboardOpen.current = true;
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
	// fully open. Visibility must therefore never be gated on a non-zero inset.
	it("shows with the keyboard up even when the inset reads 0", () => {
		insetValue.current = 0;
		mount("hello");
		const bar = screen.getByRole("toolbar", { name: "Editor actions" });
		expect(bar).toBeInTheDocument();
		// bottom-0 with no lift is already correct there: the viewport shrank.
		expect(bar.style.transform).toBe("translateY(-0px)");
	});

	// Focus alone is not enough either: dismissing the keyboard with the
	// platform's own hide button leaves the editor focused, and the bar was
	// stranding itself over the document.
	it("hides once the keyboard is dismissed, even with the editor still focused", () => {
		keyboardOpen.current = false;
		mount("hello");
		expect(screen.queryByRole("toolbar", { name: "Editor actions" })).toBeNull();
	});

	it("stops reserving bottom space once the keyboard is dismissed", () => {
		keyboardOpen.current = false;
		mount("hello");
		expect(document.documentElement.style.getPropertyValue("--editor-toolbar-offset")).toBe("");
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

	// `touch-action: pan-x` is what makes the row scrollable, and it also makes
	// pointerdown NON-cancelable for touch in Chrome — so the preventDefault
	// guard above silently stops working there and the pan blurs the editor,
	// closing the keyboard. Restoring focus when the gesture ends puts the caret
	// and the keyboard back, inside the same user gesture.
	it("returns focus to the editor when a gesture on the bar ends", () => {
		mount("hello");
		const bar = screen.getByRole("toolbar", { name: "Editor actions" });
		view.contentDOM.blur();
		expect(view.hasFocus).toBe(false);

		fireEvent.pointerUp(bar);
		expect(view.hasFocus).toBe(true);
	});

	// A tap on the row BACKGROUND moves focus to <body>, not onto a toolbar
	// element, so useEditorFocused's toolbar tolerance cannot save it. Without a
	// hold the bar unmounts on that blur and the gesture ends on a detached
	// node — so the handler that would put focus back never runs at all.
	it("stays mounted through a gesture even if focus is lost entirely", () => {
		mount("hello");
		const bar = screen.getByRole("toolbar", { name: "Editor actions" });
		fireEvent.pointerDown(bar);
		act(() => view.contentDOM.blur());
		expect(screen.queryByRole("toolbar", { name: "Editor actions" })).toBeInTheDocument();
	});

	// A pan that the browser takes over ends in pointercancel, NOT pointerup.
	it("restores focus when the browser cancels the pointer to pan", () => {
		mount("hello");
		const bar = screen.getByRole("toolbar", { name: "Editor actions" });
		fireEvent.pointerDown(bar);
		act(() => view.contentDOM.blur());
		expect(view.hasFocus).toBe(false);

		fireEvent.pointerCancel(bar);
		expect(view.hasFocus).toBe(true);
	});

	it("releases the hold once the gesture ends", () => {
		mount("hello");
		const bar = screen.getByRole("toolbar", { name: "Editor actions" });
		fireEvent.pointerDown(bar);
		fireEvent.pointerCancel(bar);
		act(() => view.contentDOM.blur());
		expect(screen.queryByRole("toolbar", { name: "Editor actions" })).toBeNull();
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

	// The setup-checklist FAB is fixed to the same bottom edge and was landing on
	// top of the toolbar once the keyboard opened. It reads this variable rather
	// than duplicating the inset measurement, so it clears the taller two-row
	// layout too. (happy-dom has no layout engine, so the measured height is 0
	// here and the value is the inset alone.)
	describe("--editor-toolbar-offset", () => {
		function offset() {
			return document.documentElement.style.getPropertyValue("--editor-toolbar-offset");
		}

		it("publishes the space it occupies while it is up", () => {
			mount("hello");
			expect(offset()).toBe("300px");
		});

		it("clears the offset when the editor loses focus", () => {
			const { unmount } = mount("hello");
			unmount();
			expect(offset()).toBe("");
		});

		it("publishes nothing on desktop, where the bar never renders", () => {
			setViewport("desktop");
			mount("hello");
			expect(offset()).toBe("");
		});
	});

	describe("inline emphasis", () => {
		it.each([
			["Bold", "**thing**"],
			["Italic", "*thing*"],
			["Strikethrough", "~~thing~~"],
		])("%s wraps the selection", (label, expected) => {
			mount("thing");
			view.dispatch({ selection: { anchor: 0, head: 5 } });
			fireEvent.click(screen.getByRole("button", { name: label }));
			expect(view.state.doc.toString()).toBe(expected);
		});

		it("un-bolds on a second tap instead of doubling the markers", () => {
			mount("thing");
			view.dispatch({ selection: { anchor: 0, head: 5 } });
			fireEvent.click(screen.getByRole("button", { name: "Bold" }));
			fireEvent.click(screen.getByRole("button", { name: "Bold" }));
			expect(view.state.doc.toString()).toBe("thing");
		});
	});

	// Eleven buttons do not fit a phone, so the row pans under a finger rather
	// than shrinking the targets. The scrollbar is hidden because a visible
	// track on a 56px-tall strip is noise. happy-dom has no layout engine, so
	// this asserts the contract rather than measured geometry.
	it("lets the command row pan horizontally without showing a track", () => {
		mount("hello");
		const row = screen.getByRole("region", { name: "Editor commands" });
		expect(row.className).toContain("overflow-x-auto");
		expect(row.className).toContain("[scrollbar-width:none]");
	});

	// The reason the row scrolls at all: full 44px tap targets (WCAG 2.5.5)
	// rather than eleven cramped ones squeezed into the width.
	it("keeps thumb-sized tap targets instead of shrinking to fit", () => {
		mount("hello");
		expect(screen.getByRole("region", { name: "Editor commands" }).className).toContain(
			"[&>button]:size-11",
		);
	});

	describe("heading picker", () => {
		it("keeps the six levels out of the way until asked", () => {
			mount("title");
			expect(screen.queryByRole("button", { name: "Heading 1" })).toBeNull();
		});

		it("slides the six levels up when the heading button is tapped", () => {
			mount("title");
			fireEvent.click(screen.getByRole("button", { name: "Heading" }));
			for (const level of [1, 2, 3, 4, 5, 6]) {
				expect(screen.getByRole("button", { name: `Heading ${level}` })).toBeInTheDocument();
			}
		});

		it("applies the chosen level and closes", () => {
			mount("title");
			fireEvent.click(screen.getByRole("button", { name: "Heading" }));
			fireEvent.click(screen.getByRole("button", { name: "Heading 3" }));
			expect(view.state.doc.toString()).toBe("### title");
			expect(screen.queryByRole("button", { name: "Heading 3" })).toBeNull();
		});

		// The picker rows live INSIDE the toolbar so the nav's pointerdown guard
		// covers them too — a row that portals out would blur the editor, drop the
		// keyboard, and unmount the whole bar mid-tap.
		it("does not let a press on the level row move focus off the editor", () => {
			mount("title");
			fireEvent.click(screen.getByRole("button", { name: "Heading" }));
			const evt = new PointerEvent("pointerdown", { bubbles: true, cancelable: true });
			fireEvent(screen.getByRole("button", { name: "Heading 2" }), evt);
			expect(evt.defaultPrevented).toBe(true);
		});
	});

	// The whole point of the button is landing INSIDE the brackets: a caret left
	// outside them means typing a note name produces "[[]]name".
	it("inserts an empty wikilink with the caret between the brackets", () => {
		mount("");
		fireEvent.click(screen.getByRole("button", { name: "Wiki link" }));
		expect(view.state.doc.toString()).toBe("[[]]");
		expect(view.state.selection.main.head).toBe(2);
	});

	it("wraps a selected word in a wikilink instead of replacing it", () => {
		mount("gamma", 0);
		view.dispatch({ selection: { anchor: 0, head: 5 } });
		fireEvent.click(screen.getByRole("button", { name: "Wiki link" }));
		expect(view.state.doc.toString()).toBe("[[gamma]]");
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

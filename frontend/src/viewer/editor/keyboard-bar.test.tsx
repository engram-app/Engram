import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { KeyboardBar } from "./keyboard-bar";

const { insetValue } = vi.hoisted(() => ({ insetValue: { current: 300 } }));
vi.mock("./use-keyboard-inset", () => ({ useKeyboardInset: () => insetValue.current }));

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc: string, at = 0) {
	view = new EditorView({
		state: EditorState.create({ doc, selection: { anchor: at, head: at } }),
		parent: document.body,
	});
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
	it("is absent while the keyboard is down", () => {
		insetValue.current = 0;
		mount("hello");
		expect(screen.queryByRole("toolbar", { name: "Editor actions" })).toBeNull();
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

	it("turns the caret line into a bullet", () => {
		mount("thing");
		fireEvent.click(screen.getByRole("button", { name: "Bullet list" }));
		expect(view.state.doc.toString()).toBe("- thing");
	});

	it("does nothing when no editor is mounted", () => {
		render(<KeyboardBar getView={() => null} />);
		fireEvent.click(screen.getByRole("button", { name: "Indent" }));
		expect(screen.getByRole("toolbar", { name: "Editor actions" })).toBeInTheDocument();
	});
});

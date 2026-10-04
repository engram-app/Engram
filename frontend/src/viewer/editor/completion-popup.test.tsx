import { autocompletion, startCompletion } from "@codemirror/autocomplete";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { act } from "react";
import { afterEach, expect, test, vi } from "vitest";
import { completionPopup, NATIVE_POPUP_CLASS } from "./completion-popup";

let view: EditorView;
afterEach(() => view?.destroy());

// React needs this flag to flush root.render() inside act().
(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

function mount() {
	view = new EditorView({
		state: EditorState.create({
			doc: "",
			selection: { anchor: 0 },
			extensions: [
				autocompletion({
					override: [
						() => ({
							from: 0,
							options: [
								{ label: "Alpha", detail: "Folder/One" },
								{ label: "Beta", detail: "Folder/Two" },
							],
						}),
					],
					tooltipClass: () => NATIVE_POPUP_CLASS,
				}),
				completionPopup,
			],
		}),
		parent: document.body,
	});
}

test("draws the suggestions with the shared ScrollArea and list rows", async () => {
	mount();
	await act(async () => {
		startCompletion(view);
	});
	const list = await vi.waitFor(() => {
		const el = document.getElementById("engram-completion-list");
		expect(el).not.toBeNull();
		return el as Element;
	});
	expect(document.querySelector('[data-slot="scroll-area"]')).not.toBeNull();
	const rows = list.querySelectorAll('[role="option"]');
	expect([...rows].map((r) => r.textContent)).toEqual(["AlphaFolder/One", "BetaFolder/Two"]);
	// First row is the selected chip, the same class the tree uses.
	expect(rows[0]).toHaveClass("bg-row-selected");
	expect(rows[1]).not.toHaveClass("bg-row-selected");
});

test("pressing a row inserts that completion", async () => {
	mount();
	await act(async () => {
		startCompletion(view);
	});
	const row = await vi.waitFor(() => {
		// Scoped to OUR list: CodeMirror's own (hidden) one is in the DOM too, and a
		// press on its rows would pass this test without exercising ours.
		const [, el] = document.querySelectorAll("#engram-completion-list [role='option']");
		expect(el).toBeDefined();
		return el as Element;
	});
	// CodeMirror ignores accepts for 75ms after the list opens (stray-Enter guard).
	await act(async () => {
		await new Promise((r) => setTimeout(r, 120));
	});
	await act(async () => {
		row.dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
	});
	expect(view.state.doc.toString()).toBe("Beta");
});

test("the editor's aria-activedescendant points at OUR selected row, not the hidden built-in list", async () => {
	mount();
	await act(async () => {
		startCompletion(view);
	});
	await vi.waitFor(() => {
		expect(view.contentDOM.getAttribute("aria-activedescendant")).toBe("engram-completion-opt-0");
	});
	expect(view.contentDOM.getAttribute("aria-controls")).toBe("engram-completion-list");
	expect(document.getElementById("engram-completion-opt-0")).not.toBeNull();
});

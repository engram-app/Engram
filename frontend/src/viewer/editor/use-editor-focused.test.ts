import { act, renderHook } from "@testing-library/react";
import { afterEach, describe, expect, it } from "vitest";
import { useEditorFocused } from "./use-editor-focused";

let editor: HTMLElement;
let toolbarButton: HTMLButtonElement;
let outside: HTMLButtonElement;

function setUp() {
	editor = document.createElement("div");
	editor.className = "cm-editor";
	const content = document.createElement("div");
	content.tabIndex = 0;
	editor.append(content);

	const toolbar = document.createElement("nav");
	toolbar.dataset.editorToolbar = "";
	toolbarButton = document.createElement("button");
	toolbar.append(toolbarButton);

	outside = document.createElement("button");
	document.body.append(editor, toolbar, outside);
	return content;
}

afterEach(() => {
	document.body.replaceChildren();
});

describe("useEditorFocused", () => {
	it("is false before anything is focused", () => {
		setUp();
		const { result } = renderHook(() => useEditorFocused());
		expect(result.current).toBe(false);
	});

	it("is true while focus is inside the editor", () => {
		const content = setUp();
		const { result } = renderHook(() => useEditorFocused());
		act(() => content.focus());
		expect(result.current).toBe(true);
	});

	// The toolbar is an extension of the editor as far as this hook cares.
	// Touch panning the command row moves focus onto the bar on browsers where
	// pointerdown is not cancelable, and treating that as "editor blurred"
	// unmounted the toolbar out from under the finger mid-drag.
	it("stays true when focus lands on the toolbar itself", () => {
		const content = setUp();
		const { result } = renderHook(() => useEditorFocused());
		act(() => content.focus());
		act(() => toolbarButton.focus());
		expect(result.current).toBe(true);
	});

	it("is false once focus leaves both the editor and the toolbar", () => {
		const content = setUp();
		const { result } = renderHook(() => useEditorFocused());
		act(() => content.focus());
		act(() => outside.focus());
		expect(result.current).toBe(false);
	});
});

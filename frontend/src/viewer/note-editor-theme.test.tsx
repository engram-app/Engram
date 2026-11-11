import { EditorView } from "@codemirror/view";
import { describe, expect, it } from "vitest";
import { Awareness } from "y-protocols/awareness";
import * as Y from "yjs";
import { englishT } from "@/i18n/translate";
import { buildEditorState } from "./note-editor";

function rules(dark: boolean): string {
	const doc = new Y.Doc();
	const state = buildEditorState(
		doc.getText("content"),
		new Awareness(doc),
		dark,
		"rendered",
		(n) => n,
		() => undefined,
		() => [],
		() => false,
		englishT,
	);
	return state
		.facet(EditorView.styleModule)
		.map((m) => m.getRules())
		.join("\n");
}

describe("editor theme", () => {
	// oneDarkTheme paints the editor root #abb2bf, so in dark mode plain
	// paragraphs read dimmer than headings and lists, which take
	// --atomic-editor-fg from atomicMarkdownSyntax. Our root rule must set the
	// body colour too, in both modes.
	it.each([true, false])("the editor root takes the body text colour (dark=%s)", (dark) => {
		const root = rules(dark)
			.split("}")
			.find((r) => r.includes("height: auto") && r.includes("background-color: transparent"));
		expect(root).toContain("color: var(--atomic-editor-fg)");
	});
});

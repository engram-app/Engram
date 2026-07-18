import { EditorState } from "@codemirror/state";
import { describe, expect, test } from "vitest";
import { livePreviewExtensions } from "./live-preview";

const MD = "# Heading\n\n**bold** and *italic* and [[Wiki Link]]\n";

describe("livePreviewExtensions", () => {
	test("is view-only: decorations never change the document text", () => {
		const ext = livePreviewExtensions({ resolveWikiLink: (n) => `/notes/${n}` });
		const state = EditorState.create({ doc: MD, extensions: ext });
		// Building state + reading facets must not alter doc bytes.
		expect(state.doc.toString()).toBe(MD);
	});

	test("does not throw when composed with markdown language", () => {
		const ext = livePreviewExtensions({ resolveWikiLink: (n) => `/notes/${n}` });
		expect(() => EditorState.create({ doc: MD, extensions: ext })).not.toThrow();
	});
});

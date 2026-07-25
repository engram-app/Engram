import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { calloutDecoration } from "./callout-decoration";

let view: EditorView;
afterEach(() => view?.destroy());

describe("calloutDecoration", () => {
	test("marks a callout block's lines without changing the doc text", () => {
		const doc = "before\n\n> [!note] Title\n> body line\n\nafter\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [calloutDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc); // view-only
		const marked = view.dom.querySelectorAll(".cm-callout.cm-callout-note");
		expect(marked.length).toBe(2); // title line + body line
	});

	test("lowercases the callout type for the class name", () => {
		const doc = "intro\n\n> [!WARNING] Careful\n> details\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [calloutDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc);
		expect(view.dom.querySelectorAll(".cm-callout-warning").length).toBe(2);
	});

	test("reveals raw source when the selection intersects the callout block", () => {
		const doc = "> [!note] Title\n> body line\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 5 },
				extensions: [calloutDecoration],
			}),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc);
		expect(view.dom.querySelectorAll(".cm-callout").length).toBe(0);
	});

	test("renders the lucide icon for an alias type (important -> tip -> flame)", () => {
		const doc = "before\n\n> [!important] Read this\n> body\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [calloutDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc); // view-only
		const title = view.dom.querySelector(".cm-callout-title");
		expect(title?.innerHTML).toContain("lucide-flame");
	});

	test("hides the raw marker and keeps a custom title", () => {
		const doc = "> [!note] My Title\n> body\n\ntail\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 30 },
				extensions: [calloutDecoration],
			}),
			parent: document.body,
		});
		const title = view.dom.querySelector(".cm-callout-title");
		expect(title?.textContent).toBe("My Title");
		expect(view.dom.textContent).not.toContain("[!note]");
	});

	test("falls back to the capitalized keyword when there is no custom title", () => {
		const doc = "> [!important]\n> body\n\ntail\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 24 },
				extensions: [calloutDecoration],
			}),
			parent: document.body,
		});
		expect(view.dom.querySelector(".cm-callout-title")?.textContent).toBe("Tip");
	});

	test("colors the block from the shared callout map", () => {
		const doc = "> [!important] x\n> body\n\ntail\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 26 },
				extensions: [calloutDecoration],
			}),
			parent: document.body,
		});
		const line = view.dom.querySelector(".cm-callout") as HTMLElement;
		// #00bfa6 is `tip`'s color in the shared map — important resolves to it.
		expect(line.style.getPropertyValue("--callout-color")).toBe("#00bfa6");
	});

	test("hides the fold marker on a foldable callout", () => {
		const doc = "> [!note]- Collapsed\n> body\n\ntail\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 30 },
				extensions: [calloutDecoration],
			}),
			parent: document.body,
		});
		expect(view.dom.querySelector(".cm-callout-title")?.textContent).toBe("Collapsed");
		expect(view.dom.textContent).not.toContain("]-");
	});

	test("leaves an unknown callout type undecorated but does not crash", () => {
		const doc = "> [!bogus] Hmm\n> body\n\ntail\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 24 },
				extensions: [calloutDecoration],
			}),
			parent: document.body,
		});
		expect(view.dom.querySelectorAll(".cm-callout").length).toBe(2);
		expect(view.dom.querySelectorAll(".cm-callout-title").length).toBe(0);
		expect(view.dom.textContent).toContain("[!bogus]");
	});

	test("does not treat an inherited Object property as a callout type", () => {
		// `types["__proto__"]` answers with Object.prototype on a plain object,
		// yielding a style whose keyword/color/svg are all undefined — the empty
		// title path then threw inside buildCallouts. CM6 catches a ViewPlugin
		// exception and disables the plugin, so the tell is the *sibling* callout
		// silently losing its decorations, not a visible error.
		const doc = "> [!__proto__]\n\n> [!note]\n> body\n\ntail\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 35 },
				extensions: [calloutDecoration],
			}),
			parent: document.body,
		});
		expect(view.dom.querySelector(".cm-callout-title")?.textContent).toBe("Note");
		expect(view.dom.textContent).toContain("[!__proto__]");
	});

	test("does not merge two adjacent callouts with no blank line between them", () => {
		const doc = "before\n\n> [!note] A\n> body\n> [!warning] B\n> body2\n\nafter\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [calloutDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc); // view-only
		expect(view.dom.querySelectorAll(".cm-callout-note").length).toBe(2);
		expect(view.dom.querySelectorAll(".cm-callout-warning").length).toBe(2);
	});
});

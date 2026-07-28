import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { useEffect } from "react";
import { afterEach, describe, expect, it } from "vitest";
import { ActiveEditorProvider, useActiveEditor } from "../editor/active-editor-context";
import MarkdownReferencePanel from "./markdown-reference-panel";

let view: EditorView | null = null;
afterEach(() => {
	view?.destroy();
	view = null;
});

/** Stands in for NotePage: publishes (or withholds) a real editor. */
function Publisher({ editor }: { editor: EditorView | null }) {
	const { setEditor } = useActiveEditor();
	useEffect(() => {
		setEditor(editor ? () => editor : null);
	}, [editor, setEditor]);
	return null;
}

function renderPanel({ withEditor = true, doc = "", caret = 0 } = {}) {
	if (withEditor) {
		view = new EditorView({
			state: EditorState.create({ doc, selection: { anchor: caret } }),
			parent: document.body,
		});
	}
	return render(
		<ActiveEditorProvider>
			<Publisher editor={view} />
			<MarkdownReferencePanel />
		</ActiveEditorProvider>,
	);
}

const search = () => screen.getByRole("searchbox", { name: /search markdown syntax/iu });

describe("MarkdownReferencePanel", () => {
	it("lists the syntax grouped under category headings", () => {
		renderPanel();
		expect(screen.getByRole("heading", { name: "Callouts" })).toBeInTheDocument();
		expect(screen.getByText("Wikilink")).toBeInTheDocument();
		expect(screen.getByText("Mermaid diagram")).toBeInTheDocument();
	});

	it("narrows the list as the user types", () => {
		renderPanel();
		fireEvent.change(search(), { target: { value: "callout" } });

		expect(screen.getByRole("heading", { name: "Callouts" })).toBeInTheDocument();
		expect(screen.queryByRole("heading", { name: "Math" })).not.toBeInTheDocument();
		expect(screen.queryByText("Wikilink")).not.toBeInTheDocument();
	});

	it("searches the keywords, not just the visible label", () => {
		renderPanel();
		fireEvent.change(search(), { target: { value: "divider" } });
		expect(screen.getByText("Horizontal rule")).toBeInTheDocument();
	});

	it("shows an empty state naming the failed query", () => {
		renderPanel();
		fireEvent.change(search(), { target: { value: "zzzznope" } });
		expect(screen.getByText(/no syntax matches/iu)).toHaveTextContent("zzzznope");
	});

	it("inserts an inline snippet at the caret", () => {
		renderPanel({ doc: "ab", caret: 1 });
		fireEvent.click(screen.getByRole("button", { name: "Insert Bold" }));
		expect(view?.state.doc.toString()).toBe("a**bold**b");
	});

	it("breaks a block snippet onto its own line", () => {
		renderPanel({ doc: "prose", caret: 5 });
		fireEvent.click(screen.getByRole("button", { name: "Insert Note callout" }));
		expect(view?.state.doc.toString()).toBe("prose\n> [!note] Title\n> Body text.");
	});

	it("inserts exactly the snippet shown in the row", () => {
		// Guards against the displayed example and the inserted text drifting apart.
		renderPanel();
		const row = screen.getByText("Wikilink").closest("li");
		const shown = within(row as HTMLElement).getByText("[[Note name]]");
		fireEvent.click(within(row as HTMLElement).getByRole("button", { name: "Insert Wikilink" }));
		expect(view?.state.doc.toString()).toBe(shown.textContent);
	});

	it("disables insertion and explains why when no note is open", () => {
		renderPanel({ withEditor: false });
		expect(screen.getByText(/open a note to insert/iu)).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Insert Bold" })).toBeDisabled();
	});

	it("drops the explanation once an editor is available", () => {
		renderPanel();
		expect(screen.queryByText(/open a note to insert/iu)).not.toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Insert Bold" })).toBeEnabled();
	});
});

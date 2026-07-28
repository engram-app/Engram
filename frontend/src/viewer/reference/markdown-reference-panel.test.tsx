import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { useEffect } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ActiveEditorProvider, useActiveEditor } from "../editor/active-editor-context";
import MarkdownReferencePanel from "./markdown-reference-panel";

// The real NoteView renders the previews (that is the point of this panel), but
// its free-tier attachment gate needs billing + query context this harness has
// no business standing up.
vi.mock("../../billing/use-is-free-tier", () => ({ useIsFreeTier: () => false }));

// jsdom neither maps <details> to role="group" nor hides collapsed content, so
// sections are located structurally and assertions are scoped to one when it
// matters.
function section(name: string): HTMLDetailsElement {
	const summary = [...document.querySelectorAll("summary")].find((el) =>
		(el.textContent ?? "").startsWith(name),
	);
	if (!summary) {
		throw new Error(`No accordion section named "${name}"`);
	}
	return summary.closest("details") as HTMLDetailsElement;
}

/**
 * Expand a category. Necessary before asserting on its rows: a closed section
 * renders no children at all (React mounts <details> children regardless of
 * `open`, so the component gates them explicitly to avoid ~29 simultaneous
 * markdown pipelines). jsdom does not action a summary click, so this drives the
 * same sequence a browser would — flip `open`, then fire the toggle event the
 * component listens for.
 */
function openSection(name: string): void {
	const details = section(name);
	details.open = true;
	fireEvent(details, new Event("toggle"));
}

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

describe("MarkdownReferencePanel — rendered previews", () => {
	it("renders the callout as an actual callout, not just its source", () => {
		// The reason the panel exists: "> [!tip]" teaches nobody anything until
		// they see what it becomes.
		renderPanel();
		openSection("Callouts");
		const row = screen.getByText("Note callout").closest("li") as HTMLElement;

		// Source is present…
		expect(within(row).getByText(/> \[!note\] Title/u)).toBeInTheDocument();
		// …and so is the rendered result, as real markup rather than literal text.
		const figure = row.querySelector("figure");
		expect(figure).not.toBeNull();
		expect(figure?.textContent).toContain("Body text.");
		expect(figure?.textContent).not.toContain("[!note]");
	});

	it("renders inline emphasis as real elements", () => {
		renderPanel();
		const row = screen.getByText("Bold").closest("li") as HTMLElement;
		expect(row.querySelector("figure strong")?.textContent).toBe("bold");
	});

	it("renders a table as a table", () => {
		renderPanel();
		openSection("Structure");
		const row = screen.getByText("Table").closest("li") as HTMLElement;
		expect(row.querySelector("figure table")).not.toBeNull();
	});

	it("omits the preview where a live render would mislead", () => {
		// Frontmatter is stripped by NoteView, and neither image form resolves
		// here — an empty or broken box teaches worse than no box.
		renderPanel();
		openSection("Properties");
		openSection("Links");
		for (const label of ["Frontmatter", "Image by URL", "Embed attachment"]) {
			const row = screen.getByText(label).closest("li") as HTMLElement;
			expect(row.querySelector("figure"), label).toBeNull();
			// The source and explanation still show.
			expect(within(row).getByRole("button", { name: `Insert ${label}` })).toBeInTheDocument();
		}
	});
});

describe("MarkdownReferencePanel — accordions", () => {
	it("opens only the first category, so the panel is not a wall of examples", () => {
		renderPanel();
		expect(section("Text")).toHaveAttribute("open");
		expect(section("Callouts")).not.toHaveAttribute("open");
		expect(section("Math")).not.toHaveAttribute("open");
	});

	it("shows how many entries a collapsed category holds", () => {
		renderPanel();
		expect(within(section("Callouts")).getByText("3")).toBeInTheDocument();
	});

	it("renders a category\u2019s rows only once it is opened", () => {
		renderPanel();
		expect(screen.queryByText("Note callout")).not.toBeInTheDocument();
		openSection("Callouts");
		expect(section("Callouts")).toHaveAttribute("open");
		expect(screen.getByText("Note callout")).toBeInTheDocument();
	});

	it("force-opens matching categories while searching", () => {
		// Hiding the hit behind a closed accordion would make search useless.
		renderPanel();
		fireEvent.change(search(), { target: { value: "callout" } });
		expect(section("Callouts")).toHaveAttribute("open");
	});
});

describe("MarkdownReferencePanel — search and insert", () => {
	it("narrows to matching categories as the user types", () => {
		renderPanel();
		fireEvent.change(search(), { target: { value: "callout" } });
		expect(screen.getByText("Note callout")).toBeInTheDocument();
		expect(screen.queryByText("Wikilink")).not.toBeInTheDocument();
	});

	it("searches keywords, not just the visible label", () => {
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
		openSection("Callouts");
		fireEvent.click(screen.getByRole("button", { name: "Insert Note callout" }));
		expect(view?.state.doc.toString()).toBe("prose\n> [!note] Title\n> Body text.");
	});

	it("inserts exactly the source shown in the row", () => {
		// Guards the displayed example and the inserted text drifting apart.
		renderPanel();
		openSection("Links");
		const row = screen.getByText("Wikilink").closest("li") as HTMLElement;
		const shown = within(row).getByText("[[Note name]]", { selector: "pre" });
		fireEvent.click(within(row).getByRole("button", { name: "Insert Wikilink" }));
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

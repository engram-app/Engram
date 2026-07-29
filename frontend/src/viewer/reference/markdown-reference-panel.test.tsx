import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { useEffect } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ThemeProvider } from "../../theme/theme-provider";
import { ActiveEditorProvider, useActiveEditor } from "../editor/active-editor-context";
import MarkdownReferencePanel from "./markdown-reference-panel";

// The real NoteView renders the previews (that is the point of this panel), but
// its free-tier attachment gate needs billing + query context this harness has
// no business standing up.
vi.mock("../../billing/use-is-free-tier", () => ({ useIsFreeTier: () => false }));

// jsdom neither maps <details> to role="group" nor hides collapsed content, so
// sections are located structurally.
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
 * same sequence a browser would.
 */
function openSection(name: string): void {
	const details = section(name);
	details.open = true;
	fireEvent(details, new Event("toggle"));
}

/**
 * Locate a row by its LABEL specifically. A plain getByText breaks on the
 * callout gallery, where the row for "note" also renders a callout whose title
 * is the word "note" — the label is always the row's first <span>.
 */
function row(label: string): HTMLElement {
	const li = [...document.querySelectorAll("li")].find(
		(el) =>
			[...el.querySelectorAll("span")].some((sp) => sp.textContent === label) ||
			// Template-led rows (Links) carry no label — the syntax identifies them.
			el.querySelector("code")?.textContent === label ||
			// Gallery rows carry no label — the callout's own title is the type name.
			el.querySelector(".callout-title")?.textContent?.trim() === label,
	);
	if (!li) {
		throw new Error(`No reference row labelled "${label}"`);
	}
	return li as HTMLElement;
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
	// ThemeProvider is real, not stubbed: opening the Code section mounts
	// MermaidBlock, which reads the resolved theme to pick its palette.
	return render(
		<ThemeProvider>
			<ActiveEditorProvider>
				<Publisher editor={view} />
				<MarkdownReferencePanel />
			</ActiveEditorProvider>
		</ThemeProvider>,
	);
}

const search = () => screen.getByRole("searchbox", { name: /search markdown syntax/iu });

describe("MarkdownReferencePanel — rendered previews", () => {
	it("renders the callout as an actual callout, not just its source", () => {
		// The reason the panel exists: "> [!tip]" teaches nobody anything until
		// they see what it becomes.
		renderPanel();
		openSection("Callouts");
		// Gallery rows render the callout directly, with no figure wrapper.
		const callout = row("note").querySelector(".callout");

		expect(callout).not.toBeNull();
		expect(callout?.textContent).toContain("Worth knowing");
		expect(callout?.textContent).not.toContain("[!note]");
	});

	it("lets the library inline the per-type colour our CSS deliberately omits", () => {
		// main.css no longer carries a callout palette — it relies on
		// @portaljs/remark-callouts inlining border-left-color from the same
		// defaultConfig map the editor's live preview reads. If the library ever
		// stops doing that, every callout silently goes neutral grey, so pin it.
		renderPanel();
		openSection("Callouts");
		const callout = row("warning").querySelector(".callout") as HTMLElement;
		expect(callout).not.toBeNull();
		expect(callout.getAttribute("style") ?? "").toMatch(/border-left-color:\s*#/u);
	});

	it("renders inline emphasis as real elements", () => {
		renderPanel();
		expect(row("Bold").querySelector("strong")?.textContent).toBe("deleted permanently");
	});

	it("renders a table as a table", () => {
		renderPanel();
		openSection("Structure");
		expect(row("Table").querySelector("figure table")).not.toBeNull();
	});

	it("omits the preview where a live render would mislead", () => {
		// Frontmatter is stripped by NoteView, and neither image form resolves
		// here — an empty or broken box teaches worse than no box.
		renderPanel();
		openSection("Properties");
		openSection("Links");
		for (const label of [
			"Frontmatter",
			"![text if the image can't load](https://example.com/photo.png)",
			"![[diagram.png]]",
		]) {
			expect(row(label).querySelector("figure"), label).toBeNull();
			expect(within(row(label)).getByRole("button", { name: /^Insert /u })).toBeInTheDocument();
		}
	});
});

describe("MarkdownReferencePanel — demo teaches, template inserts", () => {
	it("previews the worked example but inserts the neutral template", () => {
		// One string could not do both jobs: a snippet realistic enough to teach
		// is the wrong thing to drop at someone's caret.
		renderPanel({ doc: "prose", caret: 5 });
		openSection("Structure");
		const table = row("Table");

		expect(table.querySelector("figure")?.textContent).toContain("Espresso");
		expect(table.querySelector("pre")?.textContent).toBe(
			"| Column | Column |\n| --- | --- |\n| cell | cell |",
		);

		fireEvent.click(within(table).getByRole("button", { name: "Insert Table" }));
		expect(view?.state.doc.toString()).toBe(
			"prose\n| Column | Column |\n| --- | --- |\n| cell | cell |",
		);
	});

	it("shows the template verbatim, so the source line is what you get", () => {
		renderPanel();
		openSection("Structure");
		const table = row("Table");
		const shown = table.querySelector("pre")?.textContent;

		fireEvent.click(within(table).getByRole("button", { name: "Insert Table" }));
		expect(view?.state.doc.toString()).toBe(shown);
	});
});

describe("MarkdownReferencePanel — adaptive rows", () => {
	it("collapses a self-evident inline mark onto one line with no preview box", () => {
		renderPanel();
		const bold = row("Bold");
		// Result renders inline rather than in a stacked figure…
		expect(bold.querySelector("figure")).toBeNull();
		expect(bold.querySelector("strong")).not.toBeNull();
		// …and no separate source block competes with it.
		expect(bold.querySelector("pre")).toBeNull();
		expect(bold.querySelector("code")?.textContent).toBe("**text**");
	});

	it("leads a link row with its template and shows the result beside it", () => {
		// Every link variant renders as the same blue link, so the syntax is what
		// distinguishes them — a label column would only restate the brackets.
		renderPanel();
		openSection("Links");
		const wikilink = row("[[Deployment Runbook]]");
		expect(wikilink.querySelector("code")?.textContent).toBe("[[Deployment Runbook]]");
		// The rendered side is this exact template's own output, not a stand-in.
		expect(wikilink.querySelector("a")?.textContent).toBe("Deployment Runbook");
		// No label span repeating "Wikilink".
		expect(wikilink.textContent).not.toContain("Wikilink");
	});

	it("keeps the stacked anatomy for block syntax that needs it", () => {
		renderPanel();
		openSection("Code");
		const fence = row("Code block");
		expect(fence.querySelector("figure")).not.toBeNull();
		expect(fence.querySelector("pre")).not.toBeNull();
	});

	it("states a shared format once above the rows instead of on each of them", () => {
		// All thirteen callout types take the same shape, so repeating it per row
		// buried the icons those rows exist to show.
		renderPanel();
		openSection("Callouts");
		const details = section("Callouts");
		expect(details.textContent).toContain("> [!type] Title");
		// The gallery rows themselves carry no template block.
		expect(row("note").querySelector("pre")).toBeNull();
		expect(row("warning").querySelector("pre")).toBeNull();
	});

	it("renders one row per callout type, each titled with its own name", () => {
		renderPanel();
		openSection("Callouts");
		for (const type of ["note", "tip", "warning", "danger", "quote"]) {
			expect(row(type).querySelector(".callout"), type).not.toBeNull();
			expect(row(type).textContent, type).toContain(type);
		}
	});

	it("drops the row label on gallery rows, since the callout title repeats it", () => {
		renderPanel();
		openSection("Callouts");
		const note = row("note");
		// The only "note" text in the row is the callout's own title.
		expect(note.querySelectorAll(".callout-title").length).toBe(1);
		expect(note.textContent?.match(/note/gu)?.length).toBe(1);
	});

	it("gives each callout type body text that suits it", () => {
		renderPanel();
		openSection("Callouts");
		expect(row("danger").textContent).toContain("cannot be undone");
		expect(row("success").textContent).toContain("worked as intended");
	});

	it("keeps the insert button inline with the callout", () => {
		renderPanel();
		openSection("Callouts");
		const note = row("note");
		const button = within(note).getByRole("button", { name: "Insert note" });
		// A direct child of the row, so it can stretch to the row's full height —
		// not tucked inside a heading line above the preview. (jsdom applies no
		// Tailwind, so assert structure rather than computed layout.)
		expect(button.parentElement).toBe(note);
		expect(button.className).toContain("self-stretch");
	});

	it("keeps a single-line block template beside the label, not in a block of its own", () => {
		// `block` governs insertion, not layout. `---` is as self-evident as
		// `**text**`, so it should not claim a full-width row.
		renderPanel();
		openSection("Structure");
		const rule = row("Horizontal rule");
		expect(rule.querySelector("pre")).toBeNull();
		expect(rule.querySelector("code")?.textContent).toBe("---");
		// It still gets a rendered preview — that is what block means here.
		expect(rule.querySelector("figure hr")).not.toBeNull();
	});

	it("gives every heading level its own one-line row, rendered at its own size", () => {
		// "Levels 1–6" as prose is the kind of blurb we deleted elsewhere. Six
		// rows show the ladder AND make each level separately insertable.
		renderPanel();
		openSection("Structure");
		for (let level = 1; level <= 6; level++) {
			const heading = row(`Heading ${level}`);
			expect(heading.querySelector(`h${level}`), `h${level} renders`).not.toBeNull();
			// One line: template beside the label, no stacked source block.
			expect(heading.querySelector("pre"), `h${level} has no source block`).toBeNull();
			expect(heading.querySelector("code")?.textContent).toBe(`${"#".repeat(level)} Heading`);
		}
	});

	it("inserts a heading at the level whose row was clicked", () => {
		renderPanel({ doc: "prose", caret: 5 });
		openSection("Structure");
		fireEvent.click(screen.getByRole("button", { name: "Insert Heading 3" }));
		expect(view?.state.doc.toString()).toBe("prose\n### Heading");
	});

	it("shows a blurb on a one-line row instead of swallowing it", () => {
		// Regression guard: InlineRow once rendered blurbs only for entries with
		// no preview, silently hiding useful notes on inline code and others.
		renderPanel();
		expect(row("Inline code").textContent).toMatch(/no formatting is applied inside/iu);
	});

	it("drops the blurb entirely where the label already says it", () => {
		// "Bold — strong emphasis" is four ways of saying nothing.
		renderPanel();
		expect(row("Bold").textContent).not.toMatch(/emphasis/iu);
	});

	it("keeps the blurb where it carries information the preview cannot", () => {
		renderPanel();
		openSection("Callouts");
		expect(row("Foldable callout").textContent).toMatch(/starts folded/iu);
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
		// 13 generated types plus the fold-marker entry.
		expect(within(section("Callouts")).getByText("14")).toBeInTheDocument();
	});

	it("renders a category’s rows only once it is opened", () => {
		renderPanel();
		expect(screen.queryByText("Foldable callout")).not.toBeInTheDocument();
		openSection("Callouts");
		expect(section("Callouts")).toHaveAttribute("open");
		expect(screen.getByText("Foldable callout")).toBeInTheDocument();
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
		expect(screen.getByText("Foldable callout")).toBeInTheDocument();
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
		expect(view?.state.doc.toString()).toBe("a**text**b");
	});

	it("breaks a block snippet onto its own line", () => {
		renderPanel({ doc: "prose", caret: 5 });
		openSection("Callouts");
		fireEvent.click(screen.getByRole("button", { name: "Insert note" }));
		expect(view?.state.doc.toString()).toBe("prose\n> [!note] Title\n> Body.");
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

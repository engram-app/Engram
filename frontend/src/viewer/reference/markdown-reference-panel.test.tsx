import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { fireEvent, render, screen, within } from "@testing-library/react";
import { useEffect } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { ThemeProvider } from "../../theme/theme-provider";
import { ActiveEditorProvider, useActiveEditor } from "../editor/active-editor-context";
import MarkdownReferencePanel from "./markdown-reference-panel";
import { SYNTAX_ENTRIES } from "./markdown-syntax";

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
 * `open`, so the component gates them explicitly to avoid dozens of simultaneous
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
			// span OR p: block rows carry the label in a <p> of its own now that no
			// template rides beside it.
			[...el.querySelectorAll("span, p")].some((sp) => sp.textContent === label) ||
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
		expect(row("**Bold text**").querySelector("strong")?.textContent).toBe("Bold text");
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
			"![text if it can't load](https://example.com/photo.png)",
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
		const footnote = row("Footnote");

		expect(footnote.querySelector("figure")?.textContent).toContain("generous value of on time");
		expect(footnote.querySelector("pre")?.textContent).toBe("Claim.[^1]\n\n[^1]: Source.");

		fireEvent.click(within(footnote).getByRole("button", { name: "Insert Footnote" }));
		expect(view?.state.doc.toString()).toBe("prose\nClaim.[^1]\n\n[^1]: Source.");
	});

	it("makes the table its own specimen, since pipes only read next to their result", () => {
		// The one block entry with NO separate demo. Column widths and alignment
		// are unreadable apart from the source that produced them, so here the
		// template and the preview are deliberately the same string.
		renderPanel({ doc: "prose", caret: 5 });
		openSection("Structure");
		const table = row("Table");
		const shown = table.querySelector("pre")?.textContent;

		expect(shown).toBe(
			"| Left | Center | Right |\n| :--- | :---: | ---: |\n| Cell | Cell | Cell |",
		);
		expect(table.querySelector("figure table")).not.toBeNull();

		fireEvent.click(within(table).getByRole("button", { name: "Insert Table" }));
		expect(view?.state.doc.toString()).toBe(`prose\n${shown}`);
	});

	it("highlights a fenced template's body, without altering what gets inserted", () => {
		renderPanel({ doc: "prose", caret: 5 });
		openSection("Code");
		const highlighted = row("Highlighted Code Block");
		const pre = highlighted.querySelector("pre");

		// The body is tokenized in its own language…
		expect(pre?.querySelector(".hljs-keyword")?.textContent).toBe("const");
		// …while the template's TEXT stays byte-identical to the insert payload.
		// Tokenizing must decorate the source, never rewrite it.
		expect(pre?.textContent).toBe("```ts\nconst total = items.length;\n```");
		fireEvent.click(
			within(highlighted).getByRole("button", { name: "Insert Highlighted Code Block" }),
		);
		expect(view?.state.doc.toString()).toBe("prose\n```ts\nconst total = items.length;\n```");
	});

	it("leaves a fence alone when highlight.js does not know the language", () => {
		// ```mermaid is a real fence but not a real grammar. Guarding on
		// getLanguage is what keeps it from being tokenized as gibberish.
		renderPanel();
		openSection("Code");
		const mermaid = row("Mermaid Diagram");
		expect(mermaid.querySelector("pre")?.querySelector('[class*="hljs-"]')).toBeNull();
		expect(mermaid.querySelector("pre")?.textContent).toBe(
			"```mermaid\ngraph LR\n  Edit --> Sync --> Vault\n```",
		);
	});
});

// This one test opens every category at once, which is the entire catalogue
// through the real remark/KaTeX/mermaid pipeline — including mermaid's dynamic
// import. It genuinely runs past vitest's 5s default under parallel load: it
// passed alone every time and timed out in the full suite, which is the shape
// of a budget that is too small rather than a race. Raised deliberately instead
// of split per category, because splitting pays for a fresh panel mount eight
// times over to save nothing.
const LONG = 30_000;

describe("MarkdownReferencePanel — every entry actually renders", () => {
	it(
		"renders a row for every entry, through the real NoteView",
		() => {
			// The panel's premise is that previews go through the app's own renderer
			// rather than a lookalike, which means a bad entry takes the panel down
			// with a thrown remark/KaTeX/mermaid error rather than just looking wrong.
			// No test swept all of them before this — Math, the KaTeX one and so the
			// likeliest to throw, was opened by none at all — so an entry that took
			// the panel down could be added with every suite still green.
			renderPanel();
			const categories = [...new Set(SYNTAX_ENTRIES.map((e) => e.category))];
			for (const category of categories) {
				openSection(category);
			}
			// Every entry reaches the DOM: the insert button is the one element every
			// row shape renders, whichever layout the entry falls into.
			for (const entry of SYNTAX_ENTRIES) {
				expect(screen.getByRole("button", { name: `Insert ${entry.label}` })).not.toBeNull();
			}
		},
		LONG,
	);
});

describe("MarkdownReferencePanel — the ? help tip", () => {
	it("stays out of the way until asked", () => {
		renderPanel();
		// Nothing of the explanation is in the DOM before the ? is clicked. The
		// point of moving it behind the affordance was that a permanent block of
		// prose costs every later visit a scroll past something already read.
		expect(screen.queryByRole("heading", { name: "Markdown" })).toBeNull();
		expect(screen.getByRole("button", { name: "About markdown" })).not.toBeNull();
	});

	// getByRole, not findByRole: Radix mounts the popover in the same commit as
	// the click, so there is nothing to wait for. An await here would make the
	// test depend on a 1s timeout instead, which the full suite blew through
	// under parallel load while this file passed on its own every time.
	it("says what markdown is, in the inventor's own words, with a source to check", () => {
		renderPanel();
		fireEvent.click(screen.getByRole("button", { name: "About markdown" }));
		const dialog = screen.getByRole("dialog");
		// The quote is Gruber's, verbatim from daringfireball.net. Paraphrasing it
		// would put words in his mouth, so it is pinned here.
		expect(dialog.textContent).toMatch(/publishable as-is, as plain text/u);
		// Every claim in it is checkable: the original, the spec our renderer
		// implements, and the flavour the extras below come from.
		const hrefs = [...dialog.querySelectorAll("a")].map((a) => a.getAttribute("href"));
		expect(hrefs).toEqual([
			"https://daringfireball.net/projects/markdown/syntax",
			"https://commonmark.org/help/",
			"https://help.obsidian.md/syntax",
		]);
	});

	it("opens on CLICK, so the links inside it can be reached", () => {
		// Regression guard against "make it a Tooltip": a hover tooltip closes when
		// the pointer leaves the trigger, which puts these three links permanently
		// out of reach — and gives touch users no way in at all.
		renderPanel();
		const trigger = screen.getByRole("button", { name: "About markdown" });
		fireEvent.pointerEnter(trigger);
		fireEvent.mouseOver(trigger);
		expect(screen.queryByRole("dialog")).toBeNull();
		fireEvent.click(trigger);
		expect(screen.getByRole("dialog")).not.toBeNull();
	});
});

describe("MarkdownReferencePanel — adaptive rows", () => {
	it("keeps a self-evident inline mark on one line with no preview box", () => {
		renderPanel();
		const bold = row("**Bold text**");
		// Result renders inline rather than in a stacked figure…
		expect(bold.querySelector("figure")).toBeNull();
		expect(bold.querySelector("strong")).not.toBeNull();
		// …and no separate source block competes with it.
		expect(bold.querySelector("pre")).toBeNull();
		expect(bold.querySelector("code")?.textContent).toBe("**Bold text**");
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
		const fence = row("Code Block");
		expect(fence.querySelector("figure")).not.toBeNull();
		expect(fence.querySelector("pre")).not.toBeNull();
	});

	it("explains heading nesting once, as convention rather than rule", () => {
		// WCAG does not actually forbid skipping levels, and the outline algorithm
		// that would have given multiple <h1>s meaning was dropped from the spec —
		// so the wording has to stay honest about what it is.
		renderPanel();
		openSection("Headings");
		const text = section("Headings").textContent ?? "";
		expect(text).toMatch(/convention/iu);
		expect(text).toMatch(/one level at a time/iu);
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

	it("stacks the divider as heading, template block, then a boxed specimen", () => {
		// A lone horizontal rule is the one result that is not self-evident: it
		// reads as the panel's own row separator. The box says "this is the
		// example", and the template block ties the dashes to the line they drew.
		renderPanel();
		openSection("Structure");
		const rule = row("Section Divider");
		// The template block also carries context lines, so pin the INSERT PAYLOAD
		// specifically — that is the part the panel promises is what you get.
		expect(rule.querySelector('[title="Inserted at the cursor"]')?.textContent).toBe("---");
		// The blank line the rule needs is shown, not described.
		expect(rule.querySelector("pre")?.textContent).toContain("leave this line empty");
		expect(rule.querySelector("figure hr")).not.toBeNull();
		expect(rule.querySelector("figure")?.className).toContain("border");
	});

	it("gives every heading level its own one-line row, rendered at its own size", () => {
		// "Levels 1–6" as prose is the kind of blurb we deleted elsewhere. Six
		// rows show the ladder AND make each level separately insertable.
		renderPanel();
		openSection("Headings");
		for (let level = 1; level <= 6; level++) {
			const template = `${"#".repeat(level)} Heading ${level}`;
			const heading = row(template);
			expect(heading.querySelector(`h${level}`), `h${level} renders`).not.toBeNull();
			// One line: template then result, no stacked source block, no label.
			expect(heading.querySelector("pre"), `h${level} has no source block`).toBeNull();
			expect(heading.querySelector("code")?.textContent).toBe(template);
		}
	});

	it("inserts a heading at the level whose row was clicked", () => {
		renderPanel({ doc: "prose", caret: 5 });
		openSection("Headings");
		fireEvent.click(screen.getByRole("button", { name: "Insert Heading 3" }));
		expect(view?.state.doc.toString()).toBe("prose\n### Heading 3");
	});

	it("shows a blurb on a one-line row instead of swallowing it", () => {
		// Regression guard: blurbs were once rendered only for entries with no
		// preview, silently hiding useful notes on inline code and others.
		renderPanel();
		expect(row("`inline code`").textContent).toMatch(/no formatting is applied inside/iu);
	});

	it("drops the blurb entirely where the label already says it", () => {
		// "Bold — strong emphasis" is four ways of saying nothing.
		renderPanel();
		expect(row("**Bold text**").textContent).not.toMatch(/emphasis/iu);
	});

	it("keeps the blurb where it carries information the preview cannot", () => {
		renderPanel();
		openSection("Callouts");
		expect(row("Foldable Callout").textContent).toMatch(/starts folded/iu);
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
		expect(screen.queryByText("Foldable Callout")).not.toBeInTheDocument();
		openSection("Callouts");
		expect(section("Callouts")).toHaveAttribute("open");
		expect(screen.getByText("Foldable Callout")).toBeInTheDocument();
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
		expect(screen.getByText("Foldable Callout")).toBeInTheDocument();
		expect(screen.queryByText("Wikilink")).not.toBeInTheDocument();
	});

	it("searches keywords, not just the visible label", () => {
		renderPanel();
		fireEvent.change(search(), { target: { value: "horizontal rule" } });
		expect(screen.getByText("Section Divider")).toBeInTheDocument();
	});

	it("shows an empty state naming the failed query", () => {
		renderPanel();
		fireEvent.change(search(), { target: { value: "zzzznope" } });
		expect(screen.getByText(/no syntax matches/iu)).toHaveTextContent("zzzznope");
	});

	it("inserts an inline snippet at the caret", () => {
		renderPanel({ doc: "ab", caret: 1 });
		fireEvent.click(screen.getByRole("button", { name: "Insert Bold" }));
		expect(view?.state.doc.toString()).toBe("a**Bold text**b");
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

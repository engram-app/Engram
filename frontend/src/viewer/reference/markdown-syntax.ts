import { defaultConfig } from "@portaljs/remark-callouts";

// The markdown surface Engram actually renders, as data.
//
// TRUTHFULNESS RULE: every entry here must round-trip through NoteView. That
// renderer's plugin set (note-view.tsx) is the contract:
//   remark-gfm .......... tables, strikethrough, task lists, autolinks, footnotes
//   remark-math + KaTeX .. $inline$ and $$block$$
//   remark-callouts ...... > [!note] admonitions
//   remark-wiki-link ..... [[Page]] and [[Page|alias]]
//   rehype-highlight ..... fenced code with a language tag
//   MermaidBlock ......... ```mermaid fences
//   gray-matter .......... --- frontmatter --- (surfaced as note properties)
//
// Deliberately ABSENT because we do not render them: raw inline HTML (no
// rehype-raw), ==highlight==, and comments (%% %%). Listing syntax that
// silently does nothing is worse than omitting it.
//
// TWO STRINGS, TWO JOBS. `syntax` is what Insert drops at the caret, so it is a
// neutral template you overwrite. `demo` is what the preview renders, so it is
// realistic prose showing what the feature is FOR. One string could not serve
// both: sharing it produced tautologies like `**bold**` rendering the word
// "bold" beneath a label reading "Bold" — four ways of saying nothing. `demo` is
// optional and falls back to `syntax` wherever the template already teaches.
//
// Sample text never names its own feature, for that same reason. Where an
// example needs a URL or a product name, it points at Engram's own docs rather
// than some unrelated third party — this is our reference, not a tour of the
// ecosystem.

interface SyntaxEntry {
	id: string;
	category: string;
	label: string;
	/** Inserted at the caret. A neutral template, not a worked example. */
	syntax: string;
	/** Rendered in the preview. Defaults to `syntax`. Set it when realism teaches more. */
	demo?: string;
	/**
	 * Only set when it says something the label and preview cannot. A blurb that
	 * restates the label ("Bold — strong emphasis") is noise and belongs nowhere.
	 */
	blurb?: string;
	/** Only valid at the start of a line — insertSnippet adds the breaks. */
	block?: boolean;
	/** Extra search terms that do not appear in the label, syntax, or blurb. */
	keywords?: string[];
	/**
	 * Lead the row with the TEMPLATE rather than a label. For links every
	 * variant renders as the same blue link, so the syntax — not the result and
	 * not a name — is what tells them apart, and a label column just repeats in
	 * words what the brackets already say.
	 */
	templateLed?: true;
	/**
	 * The row shows its rendered result only. For categories where every entry
	 * shares one format, that format is documented once in CATEGORY_INTROS —
	 * repeating it on every callout row would bury the thing they exist to
	 * show.
	 */
	hideTemplate?: true;
	/**
	 * Set false for entries whose live render would MISLEAD rather than teach:
	 * frontmatter (NoteView strips it, leaving an empty box), and the two image
	 * forms (neither a remote URL nor a vault attachment resolves here, so both
	 * render broken). Those show source + description only.
	 */
	renderable?: false;
	/**
	 * Render as a heading, a template block, then a BORDERED preview.
	 *
	 * For the one entry whose rendered output is itself a horizontal line:
	 * unframed, the rule read as the panel's own row divider and appeared to
	 * split the section in two rather than being the specimen, and a small label
	 * beside an inline `---` never connected the dashes to the line they drew.
	 */
	framed?: true;
	/**
	 * Context lines shown around the template in a framed row, for syntax whose
	 * rule is about what surrounds it. An EMPTY STRING renders as a labelled
	 * "leave this line empty" ghost — the blank line the divider needs is
	 * invisible by definition, so stating it in prose was the only alternative.
	 *
	 * Display only. Insert still drops `syntax` and nothing else. Keep `demo` in
	 * step with these: the whole point is that the rendered specimen below is the
	 * template above, so a mismatch teaches the wrong spacing.
	 */
	templatePrelude?: readonly string[];
	templatePostlude?: readonly string[];
	/**
	 * A real outbound link for syntax that is a doorway to someone else's whole
	 * language — Mermaid's diagram grammar, say. One row can show that the fence
	 * exists; it cannot document the language inside it, and pretending otherwise
	 * is how a reference goes stale.
	 *
	 * Distinct from the inert anchors in previews, which only need to LOOK like
	 * links. Category-wide equivalents live in CATEGORY_INTROS.
	 */
	link?: { href: string; label: string };
}

/**
 * A line of body text that suits each type, so the gallery reads as thirteen
 * worked examples rather than thirteen repetitions of a word. Keyed by type; a
 * type the library adds later falls back to something neutral rather than
 * breaking the build.
 */
const CALLOUT_BODIES: Record<string, string> = {
	note: "Worth knowing, but not urgent.",
	tip: "A better way to do the same thing.",
	warning: "Check this before you continue.",
	abstract: "The short version, up front.",
	info: "Background you may want.",
	todo: "Still outstanding.",
	success: "That worked as intended.",
	question: "Something worth asking.",
	failure: "That did not work.",
	danger: "This cannot be undone.",
	bug: "A known problem, not yet fixed.",
	example: "Here is one, concretely.",
	quote: "Said better by someone else.",
};

/**
 * One row per callout TYPE, generated from the library's own map rather than
 * typed out — 13 base types today, plus 14 aliases that share their icons. A
 * hand-written list would silently fall behind a library upgrade, and this
 * section exists precisely to answer "which types are there and what do they
 * look like".
 *
 * The title of each demo is the type's own name on purpose: mapping name →
 * icon → colour IS the information. `hideTemplate` keeps the rows to just that
 * mapping, because the format is spelled out once above them (CATEGORY_INTROS).
 */
const CALLOUT_GALLERY: readonly SyntaxEntry[] = Object.entries(defaultConfig.types)
	.filter(([, value]) => typeof value === "object")
	.map(([type]) => ({
		id: `callout-${type}`,
		category: "Callouts",
		label: type,
		syntax: `> [!${type}] Title\n> Body.`,
		demo: `> [!${type}] ${type}\n> ${CALLOUT_BODIES[type] ?? "Example text."}`,
		block: true as const,
		hideTemplate: true as const,
		keywords: ["callout", "admonition", "aside", "banner"],
	}));

/** Shown once, prominently, above a category whose rows all share one format. */
export const CATEGORY_INTROS: Record<
	string,
	{ syntax?: string; note: string; link?: { href: string; label: string } }
> = {
	Headings: {
		// Deliberately worded as convention, because that is what it is: WCAG
		// requires headings be descriptive and their relationships programmatically
		// determinable (SC 1.3.1, 2.4.6) but does not forbid skipping levels, and
		// the HTML5 outline algorithm that would have given multiple <h1>s meaning
		// was never implemented and was dropped from the spec in 2022. What remains
		// true is that the SEQUENCE is what screen readers and our own Outline panel
		// read, so a gap in it is a gap in the outline.
		note: "Every heading becomes a line in the Outline panel, which is generated from these. Step down one level at a time; jumping ## to #### leaves a gap in it. By convention # is the note title, which your filename already gives you, so most notes start at ##.",
	},
	Callouts: {
		syntax: "> [!type] Title\n> Body text.",
		note: "Swap `type` for any name below. The title is optional.",
	},
	Math: {
		// The one category whose syntax is a doorway to an entire other language.
		// Two rows can show WHERE math goes but not what can go in it, and the
		// honest answer — a large subset of LaTeX, not all of it — is only useful
		// alongside the list of what made the cut. Hence a real outbound link,
		// unlike the Links section's examples, which deliberately point at us.
		note: "Formulas are written in LaTeX and typeset by KaTeX. Single dollar signs keep one in the flow of a sentence; a pair on their own lines centres it as a block. KaTeX covers a large subset of LaTeX rather than all of it, so if a command renders as red source text, it is not supported.",
		link: {
			href: "https://ashki23.github.io/markdown-latex.html#latex",
			label: "LaTeX syntax reference",
		},
	},
};

/**
 * The catalogue. The panel reads it through `filterSyntax` / `groupByCategory`
 * rather than directly; it is exported for the tests that assert invariants
 * across EVERY entry (chiefly the TRUTHFULNESS RULE above — that each one
 * round-trips through NoteView). Not dead, and not a second read path.
 */
export const SYNTAX_ENTRIES: readonly SyntaxEntry[] = [
	// ── Text ────────────────────────────────────────────────────────────────
	{
		id: "bold",
		category: "Text",
		label: "Bold",
		syntax: "**Bold text**",
		keywords: ["strong", "emphasis"],
		templateLed: true,
	},
	{
		id: "italic",
		category: "Text",
		label: "Italic",
		syntax: "*Italic text*",
		keywords: ["emphasis", "em"],
		templateLed: true,
	},
	{
		id: "bold-italic",
		category: "Text",
		label: "Bold italic",
		syntax: "***Bold italic text***",
		keywords: ["strong", "emphasis"],
		templateLed: true,
	},
	{
		id: "strikethrough",
		category: "Text",
		label: "Strikethrough",
		syntax: "~~Struck through~~",
		keywords: ["strike", "delete", "gfm"],
		templateLed: true,
	},
	{
		id: "inline-code",
		category: "Text",
		label: "Inline code",
		syntax: "`inline code`",
		blurb: "No formatting is applied inside.",
		keywords: ["monospace", "backtick"],
		templateLed: true,
	},

	// ── Structure ───────────────────────────────────────────────────────────
	// One row per level. Reading down them shows the size ladder AND a real
	// document outline, which is what a prose blurb saying "levels 1-6" could
	// never do — and each level is separately insertable.
	{
		id: "heading-1",
		category: "Headings",
		label: "Heading 1",
		syntax: "# Heading 1",
		block: true,
		keywords: ["title", "h1", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-2",
		category: "Headings",
		label: "Heading 2",
		syntax: "## Heading 2",
		block: true,
		keywords: ["title", "h2", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-3",
		category: "Headings",
		label: "Heading 3",
		syntax: "### Heading 3",
		block: true,
		keywords: ["title", "h3", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-4",
		category: "Headings",
		label: "Heading 4",
		syntax: "#### Heading 4",
		block: true,
		keywords: ["title", "h4", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-5",
		category: "Headings",
		label: "Heading 5",
		syntax: "##### Heading 5",
		block: true,
		keywords: ["title", "h5", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-6",
		category: "Headings",
		label: "Heading 6",
		syntax: "###### Heading 6",
		block: true,
		keywords: ["title", "h6", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "bullet-list",
		category: "Structure",
		label: "Bullet list",
		syntax: "- Bullet item",
		block: true,
		keywords: ["unordered", "ul"],
		templateLed: true,
	},
	{
		id: "numbered-list",
		category: "Structure",
		label: "Numbered list",
		syntax: "1. Numbered item",
		block: true,
		keywords: ["ordered", "ol"],
		templateLed: true,
	},
	{
		id: "task-list",
		category: "Structure",
		label: "Task list",
		// Both states in the template, so the left column shows the ONE character
		// that distinguishes them. `demo` would split what is inserted from what is
		// rendered for no gain here — the template already reads as an example.
		syntax: "- [ ] Unchecked item\n- [x] Checked item",
		block: true,
		keywords: ["checkbox", "todo", "checklist", "gfm"],
		templateLed: true,
	},
	{
		id: "blockquote",
		category: "Structure",
		label: "Blockquote",
		syntax: "> Quoted text",
		block: true,
		keywords: ["quote", "cite"],
		templateLed: true,
	},
	// Three near-identical rows rather than one row with a "nest with >>" blurb.
	// Depth is drawn — one rail per level — so three stacked previews show the
	// ladder at a glance, which is the thing a sentence has to describe badly.
	{
		id: "blockquote-nested",
		category: "Structure",
		label: "Nested quote",
		syntax: ">> Nested once",
		block: true,
		keywords: ["quote", "cite", "nest", "nested", "depth"],
		templateLed: true,
	},
	{
		id: "blockquote-nested-twice",
		category: "Structure",
		label: "Twice-nested quote",
		syntax: ">>> Nested twice",
		block: true,
		keywords: ["quote", "cite", "nest", "nested", "depth"],
		templateLed: true,
	},
	{
		id: "rule",
		category: "Structure",
		// "Section divider" over "Horizontal rule": the label has to say what the
		// thing is FOR, because the rendered line alone tells you nothing. The
		// technical names stay searchable via keywords.
		label: "Section Divider",
		syntax: "---",
		templatePrelude: ["Text above the divider", ""],
		templatePostlude: ["Text below the divider"],
		// Character-for-character the template above: blank line before the dashes,
		// none after. The specimen has to BE the template, or the row teaches one
		// spacing and demonstrates another.
		//
		// The surrounding prose is also load-bearing for a second reason: NoteView
		// runs gray-matter, which swallows a leading "---" as a frontmatter
		// delimiter and previews an empty box.
		demo: "Text above the divider\n\n---\nText below the divider",
		// No blurb. The blank-line rule used to be spelled out here; the template's
		// ghost line now SHOWS it, and the sentence beside it was saying the same
		// thing a second time.
		block: true,
		framed: true,
		keywords: ["divider", "hr", "separator", "break", "horizontal", "rule", "line"],
	},
	{
		id: "table",
		category: "Structure",
		label: "Table",
		// No separate `demo` here, unlike the other block entries: a table's
		// column widths, alignment and header shading only make sense next to the
		// pipes that produced them, so the specimen has to BE the template. It is
		// still a fine thing to drop at a caret — a two-column starter you edit.
		// Self-describing, like the Text rows: each column is NAMED for the
		// alignment its divider marker sets, so the specimen demonstrates all three
		// markers instead of a sentence listing them.
		syntax: "| Left | Center | Right |\n| :--- | :---: | ---: |\n| Cell | Cell | Cell |",
		blurb:
			"The divider row sets each column's alignment. Right-click a table in a note to insert or delete rows and columns.",
		block: true,
		keywords: ["grid", "columns", "gfm"],
	},
	{
		id: "footnote",
		category: "Structure",
		label: "Footnote",
		syntax: "Claim.[^1]\n\n[^1]: Source.",
		demo: "Shipped on time.[^1]\n\n[^1]: For a generous value of on time.",
		blurb: "Numbered automatically, with a link back.",
		block: true,
		keywords: ["citation", "reference", "gfm"],
	},

	// ── Links & embeds ──────────────────────────────────────────────────────
	{
		id: "wikilink",
		category: "Links",
		label: "Wikilink",
		syntax: "[[Deployment Runbook]]",
		templateLed: true,
		keywords: ["internal", "backlink", "obsidian", "link"],
	},
	{
		id: "wikilink-alias",
		category: "Links",
		label: "Wikilink with alias",
		// Same note as the row above, so the pair reads as one idea; the alias is a
		// realistic shorthand rather than the word "alias".
		syntax: "[[Deployment Runbook|the runbook]]",
		blurb: "The pipe sets the display text.",
		templateLed: true,
		keywords: ["internal", "pipe", "obsidian", "link"],
	},
	{
		id: "link",
		category: "Links",
		label: "External link",
		syntax: "[Engram docs](https://engram.page/docs)",
		templateLed: true,
		keywords: ["url", "href", "hyperlink", "external", "link"],
	},
	{
		id: "image",
		category: "Links",
		label: "Image by URL",
		// The placeholder says what alt text is FOR. "alt" is jargon that teaches
		// nobody, and this string is what lands in the note, so it should read as
		// an instruction to replace.
		// No blurb: the placeholder text explains itself, and "any image on the
		// web" only restated the URL sitting right beside it.
		syntax: "![text if it can't load](https://example.com/photo.png)",
		renderable: false,
		templateLed: true,
		keywords: ["picture", "img", "photo", "link"],
	},
	{
		id: "embed",
		category: "Links",
		label: "Embed attachment",
		syntax: "![[diagram.png]]",
		blurb: "A file from your vault.",
		renderable: false,
		templateLed: true,
		keywords: ["attachment", "transclude", "obsidian", "pdf", "embed", "link"],
	},

	...CALLOUT_GALLERY,

	// ── Callouts: fold markers ────────────────────────────────────────────────────────────
	{
		id: "callout-foldable",
		category: "Callouts",
		label: "Foldable Callout",
		syntax: "> [!tip]- Title\n> Body.",
		// No demo, and not previewed: @portaljs/remark-callouts does not consume
		// the fold marker, so remark parses the "- Title" that follows as a BULLET
		// LIST and the title renders as `<ul><li>`. Showing that would teach the
		// wrong thing. It does fold correctly in Obsidian, which is why the entry
		// stays — but the blurb has to say where it works.
		blurb:
			"Obsidian only: - starts folded, + starts open. The web viewer shows the marker as a bullet.",
		renderable: false,
		block: true,
		keywords: ["collapse", "fold", "details", "accordion"],
	},

	// ── Code ────────────────────────────────────────────────────────────────
	{
		id: "code-fence",
		category: "Code",
		label: "Code Block",
		// The BARE fence was missing entirely — the section documented only the
		// language-tagged form, so the base syntax everyone reaches for first was
		// nowhere in the reference.
		syntax: "```\nPlain code, no highlighting\n```",
		block: true,
		keywords: ["fence", "snippet", "backticks", "preformatted", "pre", "monospace"],
	},
	{
		id: "code-fence-lang",
		category: "Code",
		label: "Highlighted Code Block",
		// Template and preview are the same string here, as with the table and the
		// diagram: `code` above a rendered `const total = items.length;` left the
		// reader matching one to the other for no gain.
		syntax: "```ts\nconst total = items.length;\n```",
		blurb:
			"Many languages are supported. Name the type straight after the opening fence. It is usually the file extension: ts for TypeScript, js for JavaScript.",
		block: true,
		keywords: ["fence", "syntax", "highlight", "snippet", "language", "ts", "js", "elixir"],
	},
	{
		id: "mermaid",
		category: "Code",
		label: "Mermaid Diagram",
		// No separate `demo`, for the same reason as the table: a diagram's shape
		// is the whole lesson, and `A --> B` above a rendered Edit → Sync → Vault
		// flow left the reader to guess which part of the source produced which
		// box. The template IS the diagram you see.
		syntax: "```mermaid\ngraph LR\n  Edit --> Sync --> Vault\n```",
		blurb: "Flowchart, sequence, class and state diagrams.",
		link: {
			href: "https://mermaid.ai/open-source/intro/syntax-reference.html",
			label: "Mermaid syntax reference",
		},
		block: true,
		keywords: ["diagram", "graph", "flowchart", "chart", "uml"],
	},

	// ── Math ────────────────────────────────────────────────────────────────
	{
		id: "math-inline",
		category: "Math",
		label: "Inline Math",
		syntax: "$E = mc^2$",
		// Blurbs dropped from both Math rows: the category intro above them now
		// carries the inline-vs-block distinction, and repeating "KaTeX" on each
		// row said it three times on one screen.
		keywords: ["katex", "latex", "tex", "equation", "formula"],
		templateLed: true,
	},
	{
		id: "math-block",
		category: "Math",
		label: "Block Math",
		syntax: "$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$",
		block: true,
		keywords: ["katex", "latex", "tex", "equation", "display"],
	},

	// ── Properties ──────────────────────────────────────────────────────────
	{
		id: "frontmatter",
		category: "Properties",
		label: "Frontmatter",
		syntax: "---\ntitle: My note\ntags: [idea, draft]\n---",
		blurb: "Must be the very first thing in the note. Shows up as note properties.",
		block: true,
		renderable: false,
		keywords: ["yaml", "metadata", "properties", "tags", "header"],
	},
	{
		id: "tag",
		category: "Properties",
		label: "Tag",
		syntax: "#topic",
		blurb: "Also settable via the tags frontmatter key.",
		keywords: ["hashtag", "label", "category"],
		templateLed: true,
	},
];

/** What the preview renders: the worked example if there is one, else the template. */
export function previewSource(entry: SyntaxEntry): string {
	return entry.demo ?? entry.syntax;
}

/**
 * Case-insensitive AND-match across every searchable field: all whitespace-
 * separated terms must appear somewhere in the entry. "block math" and
 * "math block" therefore both find block math, which a single substring test
 * on a joined string would not do reliably.
 */
export function filterSyntax(query: string): readonly SyntaxEntry[] {
	const terms = query.toLowerCase().split(/\s+/u).filter(Boolean);
	if (terms.length === 0) {
		return SYNTAX_ENTRIES;
	}
	return SYNTAX_ENTRIES.filter((entry) => {
		const haystack = [
			entry.label,
			entry.category,
			entry.syntax,
			entry.blurb ?? "",
			...(entry.keywords ?? []),
		]
			.join(" ")
			.toLowerCase();
		return terms.every((term) => haystack.includes(term));
	});
}

/** Entries grouped by category, preserving the declaration order of both. */
export function groupByCategory(
	entries: readonly SyntaxEntry[],
): readonly [string, readonly SyntaxEntry[]][] {
	const groups = new Map<string, SyntaxEntry[]>();
	for (const entry of entries) {
		const bucket = groups.get(entry.category);
		if (bucket) {
			bucket.push(entry);
		} else {
			groups.set(entry.category, [entry]);
		}
	}
	return [...groups];
}

export type { SyntaxEntry };

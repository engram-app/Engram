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
	 * repeating it on all 13 callout rows would bury the thing they exist to
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
}

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
export const CATEGORY_INTROS: Record<string, { syntax: string; note: string }> = {
	Callouts: {
		syntax: "> [!type] Title\n> Body text.",
		note: "Swap `type` for any name below. The title is optional.",
	},
};

export const SYNTAX_ENTRIES: readonly SyntaxEntry[] = [
	// ── Text ────────────────────────────────────────────────────────────────
	{
		id: "bold",
		category: "Text",
		label: "Bold",
		syntax: "**text**",
		demo: "**deleted permanently**",
		keywords: ["strong", "emphasis"],
	},
	{
		id: "italic",
		category: "Text",
		label: "Italic",
		syntax: "*text*",
		demo: "*The Pragmatic Programmer*",
		keywords: ["emphasis", "em"],
	},
	{
		id: "bold-italic",
		category: "Text",
		label: "Bold italic",
		syntax: "***text***",
		demo: "***never*** commit secrets",
		keywords: ["strong", "emphasis"],
	},
	{
		id: "strikethrough",
		category: "Text",
		label: "Strikethrough",
		syntax: "~~text~~",
		demo: "~~Tuesday~~ Thursday",
		keywords: ["strike", "delete", "gfm"],
	},
	{
		id: "inline-code",
		category: "Text",
		label: "Inline code",
		syntax: "`code`",
		demo: "run `engram sync`",
		blurb: "No formatting is applied inside.",
		keywords: ["monospace", "backtick"],
	},

	// ── Structure ───────────────────────────────────────────────────────────
	// One row per level. Reading down them shows the size ladder AND a real
	// document outline, which is what a prose blurb saying "levels 1-6" could
	// never do — and each level is separately insertable.
	{
		id: "heading-1",
		category: "Structure",
		label: "Heading 1",
		syntax: "# Heading",
		demo: "# Release notes",
		block: true,
		keywords: ["title", "h1", "toc", "outline", "section"],
	},
	{
		id: "heading-2",
		category: "Structure",
		label: "Heading 2",
		syntax: "## Heading",
		demo: "## Highlights",
		block: true,
		keywords: ["title", "h2", "toc", "outline", "section"],
	},
	{
		id: "heading-3",
		category: "Structure",
		label: "Heading 3",
		syntax: "### Heading",
		demo: "### Bug fixes",
		block: true,
		keywords: ["title", "h3", "toc", "outline", "section"],
	},
	{
		id: "heading-4",
		category: "Structure",
		label: "Heading 4",
		syntax: "#### Heading",
		demo: "#### Sync engine",
		block: true,
		keywords: ["title", "h4", "toc", "outline", "section"],
	},
	{
		id: "heading-5",
		category: "Structure",
		label: "Heading 5",
		syntax: "##### Heading",
		demo: "##### Edge cases",
		block: true,
		keywords: ["title", "h5", "toc", "outline", "section"],
	},
	{
		id: "heading-6",
		category: "Structure",
		label: "Heading 6",
		syntax: "###### Heading",
		demo: "###### Known issues",
		block: true,
		keywords: ["title", "h6", "toc", "outline", "section"],
	},
	{
		id: "bullet-list",
		category: "Structure",
		label: "Bullet list",
		syntax: "- item",
		demo: "- Espresso\n- Filter\n  - Chemex",
		blurb: "Indent two spaces to nest.",
		block: true,
		keywords: ["unordered", "ul"],
	},
	{
		id: "numbered-list",
		category: "Structure",
		label: "Numbered list",
		syntax: "1. item",
		demo: "1. Preheat\n2. Mix\n3. Bake",
		block: true,
		keywords: ["ordered", "ol"],
	},
	{
		id: "task-list",
		category: "Structure",
		label: "Task list",
		syntax: "- [ ] task",
		demo: "- [x] Draft the outline\n- [ ] Write the intro",
		blurb: "Read-only here — tick them in Obsidian.",
		block: true,
		keywords: ["checkbox", "todo", "checklist", "gfm"],
	},
	{
		id: "blockquote",
		category: "Structure",
		label: "Blockquote",
		syntax: "> quoted",
		demo: "> Simplicity is prerequisite for reliability.",
		blurb: "Nest with >>.",
		block: true,
		keywords: ["quote", "cite"],
	},
	{
		id: "rule",
		category: "Structure",
		label: "Horizontal rule",
		syntax: "---",
		// Demo carries surrounding prose for TWO reasons: a divider between two
		// paragraphs is what one is actually for, and NoteView runs gray-matter,
		// which swallows a leading "---" as a frontmatter delimiter and previews
		// an empty box.
		demo: "Above the line\n\n---\n\nBelow the line",
		blurb: "Needs a blank line above, or it turns the line before into a heading.",
		block: true,
		keywords: ["divider", "hr", "separator", "break"],
	},
	{
		id: "table",
		category: "Structure",
		label: "Table",
		syntax: "| Column | Column |\n| --- | --- |\n| cell | cell |",
		demo: "| Roast | Kg |\n| --- | ---: |\n| Espresso | 12 |\n| Filter | 3 |",
		blurb: "Use :--- and ---: in the divider row to align.",
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
		syntax: "![text if the image can't load](https://example.com/photo.png)",
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
		label: "Foldable callout",
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
		label: "Code block",
		syntax: "```ts\ncode\n```",
		demo: "```ts\nconst total = items.length;\n```",
		blurb: "Tag the language to highlight it.",
		block: true,
		keywords: ["fence", "syntax", "highlight", "snippet"],
	},
	{
		id: "mermaid",
		category: "Code",
		label: "Mermaid diagram",
		syntax: "```mermaid\ngraph TD\n  A --> B\n```",
		demo: "```mermaid\ngraph LR\n  Edit --> Sync --> Vault\n```",
		blurb: "Flowchart, sequence, class and state diagrams.",
		block: true,
		keywords: ["diagram", "graph", "flowchart", "chart", "uml"],
	},

	// ── Math ────────────────────────────────────────────────────────────────
	{
		id: "math-inline",
		category: "Math",
		label: "Inline math",
		syntax: "$x^2$",
		demo: "area grows as $r^2$",
		blurb: "KaTeX, in the flow of the sentence.",
		keywords: ["katex", "latex", "tex", "equation", "formula"],
	},
	{
		id: "math-block",
		category: "Math",
		label: "Block math",
		syntax: "$$\nx^2\n$$",
		demo: "$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$",
		blurb: "KaTeX, centred on its own line.",
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

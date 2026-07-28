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

export interface SyntaxEntry {
	id: string;
	category: string;
	label: string;
	/** Exactly what gets inserted. Keep it a runnable example, not a template. */
	syntax: string;
	blurb: string;
	/** Only valid at the start of a line — insertSnippet adds the breaks. */
	block?: boolean;
	/** Extra search terms that do not appear in the label, syntax, or blurb. */
	keywords?: string[];
}

export const SYNTAX_ENTRIES: readonly SyntaxEntry[] = [
	// ── Text ────────────────────────────────────────────────────────────────
	{
		id: "bold",
		category: "Text",
		label: "Bold",
		syntax: "**bold**",
		blurb: "Strong emphasis.",
		keywords: ["strong", "emphasis"],
	},
	{
		id: "italic",
		category: "Text",
		label: "Italic",
		syntax: "*italic*",
		blurb: "Emphasis.",
		keywords: ["emphasis", "em"],
	},
	{
		id: "bold-italic",
		category: "Text",
		label: "Bold italic",
		syntax: "***bold italic***",
		blurb: "Both at once.",
	},
	{
		id: "strikethrough",
		category: "Text",
		label: "Strikethrough",
		syntax: "~~struck~~",
		blurb: "Crossed-out text.",
		keywords: ["strike", "delete", "gfm"],
	},
	{
		id: "inline-code",
		category: "Text",
		label: "Inline code",
		syntax: "`code`",
		blurb: "Monospace, no formatting applied inside.",
		keywords: ["monospace", "backtick"],
	},

	// ── Structure ───────────────────────────────────────────────────────────
	{
		id: "heading",
		category: "Structure",
		label: "Heading",
		syntax: "## Heading",
		blurb: "Levels 1–6. Headings feed the Outline panel.",
		block: true,
		keywords: ["title", "h1", "h2", "toc", "outline"],
	},
	{
		id: "bullet-list",
		category: "Structure",
		label: "Bullet list",
		syntax: "- first\n- second",
		blurb: "Indent two spaces to nest.",
		block: true,
		keywords: ["unordered", "ul"],
	},
	{
		id: "numbered-list",
		category: "Structure",
		label: "Numbered list",
		syntax: "1. first\n2. second",
		blurb: "Ordered list.",
		block: true,
		keywords: ["ordered", "ol"],
	},
	{
		id: "task-list",
		category: "Structure",
		label: "Task list",
		syntax: "- [ ] todo\n- [x] done",
		blurb: "Checkboxes render read-only here; tick them in Obsidian.",
		block: true,
		keywords: ["checkbox", "todo", "checklist", "gfm"],
	},
	{
		id: "blockquote",
		category: "Structure",
		label: "Blockquote",
		syntax: "> quoted",
		blurb: "Nest with >>.",
		block: true,
		keywords: ["quote", "cite"],
	},
	{
		id: "rule",
		category: "Structure",
		label: "Horizontal rule",
		syntax: "---",
		blurb: "Thematic break. Needs a blank line above to avoid making a heading.",
		block: true,
		keywords: ["divider", "hr", "separator", "break"],
	},
	{
		id: "table",
		category: "Structure",
		label: "Table",
		syntax: "| Column | Column |\n| --- | --- |\n| cell | cell |",
		blurb: "Use :--- and ---: in the divider row to align.",
		block: true,
		keywords: ["grid", "columns", "gfm"],
	},
	{
		id: "footnote",
		category: "Structure",
		label: "Footnote",
		syntax: "Claim.[^1]\n\n[^1]: The supporting note.",
		blurb: "Renders as a numbered reference with a backlink.",
		block: true,
		keywords: ["citation", "reference", "gfm"],
	},

	// ── Links & embeds ──────────────────────────────────────────────────────
	{
		id: "wikilink",
		category: "Links",
		label: "Wikilink",
		syntax: "[[Note name]]",
		blurb: "Link to another note by name.",
		keywords: ["internal", "backlink", "obsidian"],
	},
	{
		id: "wikilink-alias",
		category: "Links",
		label: "Wikilink with alias",
		syntax: "[[Note name|shown text]]",
		blurb: "Same link, different display text.",
		keywords: ["internal", "pipe", "obsidian"],
	},
	{
		id: "link",
		category: "Links",
		label: "External link",
		syntax: "[label](https://example.com)",
		blurb: "Standard markdown link.",
		keywords: ["url", "href", "hyperlink"],
	},
	{
		id: "autolink",
		category: "Links",
		label: "Bare URL",
		syntax: "https://example.com",
		blurb: "Linkified automatically — no brackets needed.",
		keywords: ["autolink", "url", "gfm"],
	},
	{
		id: "image",
		category: "Links",
		label: "Image by URL",
		syntax: "![alt text](https://example.com/image.png)",
		blurb: "Remote image.",
		keywords: ["picture", "img", "photo"],
	},
	{
		id: "embed",
		category: "Links",
		label: "Embed attachment",
		syntax: "![[image.png]]",
		blurb: "Embeds a file from your vault. Fetched through the attachments API.",
		keywords: ["attachment", "transclude", "obsidian", "pdf"],
	},

	// ── Callouts ────────────────────────────────────────────────────────────
	{
		id: "callout-note",
		category: "Callouts",
		label: "Note callout",
		syntax: "> [!note] Title\n> Body text.",
		blurb: "Admonition block. The title is optional.",
		block: true,
		keywords: ["admonition", "aside", "info", "obsidian"],
	},
	{
		id: "callout-warning",
		category: "Callouts",
		label: "Warning callout",
		syntax: "> [!warning] Careful\n> Body text.",
		blurb: "Also: tip, info, danger, success, question, quote.",
		block: true,
		keywords: ["admonition", "caution", "alert"],
	},
	{
		id: "callout-foldable",
		category: "Callouts",
		label: "Foldable callout",
		syntax: "> [!tip]- Collapsed by default\n> Body text.",
		blurb: "Trailing - starts folded, + starts open.",
		block: true,
		keywords: ["collapse", "fold", "details", "accordion"],
	},

	// ── Code ────────────────────────────────────────────────────────────────
	{
		id: "code-fence",
		category: "Code",
		label: "Code block",
		syntax: "```ts\nconst x = 1;\n```",
		blurb: "Tag the language for syntax highlighting.",
		block: true,
		keywords: ["fence", "syntax", "highlight", "snippet"],
	},
	{
		id: "mermaid",
		category: "Code",
		label: "Mermaid diagram",
		syntax: "```mermaid\ngraph TD\n  A[Start] --> B[End]\n```",
		blurb: "Rendered as a diagram. Supports flowcharts, sequence, class, state.",
		block: true,
		keywords: ["diagram", "graph", "flowchart", "chart", "uml"],
	},

	// ── Math ────────────────────────────────────────────────────────────────
	{
		id: "math-inline",
		category: "Math",
		label: "Inline math",
		syntax: "$E = mc^2$",
		blurb: "KaTeX, rendered in the flow of the sentence.",
		keywords: ["katex", "latex", "tex", "equation", "formula"],
	},
	{
		id: "math-block",
		category: "Math",
		label: "Block math",
		syntax: "$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$",
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
		keywords: ["yaml", "metadata", "properties", "tags", "header"],
	},
	{
		id: "tag",
		category: "Properties",
		label: "Tag",
		syntax: "#tag",
		blurb: "Inline tag. Also settable via the tags frontmatter key.",
		keywords: ["hashtag", "label", "category"],
	},
];

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
			entry.blurb,
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

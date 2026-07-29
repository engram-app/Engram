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
// Sample text never names its own feature, for that same reason.

export interface SyntaxEntry {
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
	 * Set false for entries whose live render would MISLEAD rather than teach:
	 * frontmatter (NoteView strips it, leaving an empty box), and the two image
	 * forms (neither a remote URL nor a vault attachment resolves here, so both
	 * render broken). Those show source + description only.
	 */
	renderable?: false;
}

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
		demo: "run `mix phx.server`",
		blurb: "No formatting is applied inside.",
		keywords: ["monospace", "backtick"],
	},

	// ── Structure ───────────────────────────────────────────────────────────
	{
		id: "heading",
		category: "Structure",
		label: "Heading",
		syntax: "## Heading",
		demo: "## Deployment notes",
		blurb: "Levels 1–6. Headings feed the Outline panel.",
		block: true,
		keywords: ["title", "h1", "h2", "toc", "outline"],
	},
	{
		id: "bullet-list",
		category: "Structure",
		label: "Bullet list",
		syntax: "- item\n- item",
		demo: "- Espresso\n- Filter\n  - Chemex",
		blurb: "Indent two spaces to nest.",
		block: true,
		keywords: ["unordered", "ul"],
	},
	{
		id: "numbered-list",
		category: "Structure",
		label: "Numbered list",
		syntax: "1. item\n2. item",
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
		syntax: "[[Note name]]",
		demo: "[[Deployment Runbook]]",
		keywords: ["internal", "backlink", "obsidian"],
	},
	{
		id: "wikilink-alias",
		category: "Links",
		label: "Wikilink with alias",
		syntax: "[[Note name|shown text]]",
		demo: "[[Deployment Runbook|the runbook]]",
		blurb: "The pipe sets the display text.",
		keywords: ["internal", "pipe", "obsidian"],
	},
	{
		id: "link",
		category: "Links",
		label: "External link",
		syntax: "[label](https://example.com)",
		demo: "[Elixir docs](https://hexdocs.pm)",
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
		syntax: "![alt text](https://example.com/photo.png)",
		blurb: "Any remote image. Not previewed here — that URL is not real.",
		renderable: false,
		keywords: ["picture", "img", "photo"],
	},
	{
		id: "embed",
		category: "Links",
		label: "Embed attachment",
		syntax: "![[diagram.png]]",
		blurb: "Embeds a file from your vault. Not previewed here — no such file.",
		renderable: false,
		keywords: ["attachment", "transclude", "obsidian", "pdf"],
	},

	// ── Callouts ────────────────────────────────────────────────────────────
	{
		id: "callout-note",
		category: "Callouts",
		label: "Note callout",
		syntax: "> [!note] Title\n> Body.",
		demo: "> [!note] Good to know\n> Engram syncs as you type.",
		blurb: "The title is optional.",
		block: true,
		keywords: ["admonition", "aside", "info", "obsidian"],
	},
	{
		id: "callout-warning",
		category: "Callouts",
		label: "Warning callout",
		syntax: "> [!warning] Title\n> Body.",
		demo: "> [!warning] Back up first\n> This cannot be undone.",
		blurb: "Also tip, info, danger, success, question, quote.",
		block: true,
		keywords: ["admonition", "caution", "alert"],
	},
	{
		id: "callout-foldable",
		category: "Callouts",
		label: "Foldable callout",
		syntax: "> [!tip]- Title\n> Body.",
		demo: "> [!tip]- Hidden until you click\n> There you go.",
		blurb: "Trailing - starts folded, + starts open.",
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

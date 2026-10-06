import { defaultConfig } from "@portaljs/remark-callouts";
import { msg } from "@/i18n/msg";
import { englishT, type Translate } from "@/i18n/translate";

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
//   splitFrontmatter ..... --- frontmatter --- (surfaced as note properties)
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

/**
 * Sample prose is module-scope data but `t` exists only in components, so a
 * sample is either a plain string (nothing to translate) or a function that
 * composes the string from literal-keyed `t(...)` calls. Syntax characters stay
 * outside the calls: only the prose a user would replace is translated.
 */
type Sample = string | ((t: Translate) => string);

/** Resolve a sample with the reader's translator. */
function resolveSample(value: Sample, t: Translate): string {
	return typeof value === "function" ? value(t) : value;
}

// One word, one key: the same placeholder prose recurs across entries.
const TITLE = msg("Title");
const BODY = msg("Body.");
const CELL = msg("Cell");
const ABOVE_DIVIDER = msg("Text above the divider");
const BELOW_DIVIDER = msg("Text below the divider");
const WIKI_TARGET = msg("Deployment Runbook");
const CALLOUT_FALLBACK = msg("Example text.");

/** An entry as authored: `syntax` and `demo` may be translatable samples. */
interface EntryDef {
	id: string;
	category: string;
	label: string;
	/** Inserted at the caret. A neutral template, not a worked example. */
	syntax: Sample;
	/** Rendered in the preview. Defaults to `syntax`. Set it when realism teaches more. */
	demo?: Sample;
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
	templatePrelude?: readonly Sample[];
	templatePostlude?: readonly Sample[];
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
 * An entry as consumed. `syntax` and `demo` are the ENGLISH strings, so
 * non-React callers and the invariants in the tests keep working unchanged;
 * `sample` keeps the translatable originals for `entrySyntax` / `previewSource`.
 */
type SyntaxEntry = Omit<EntryDef, "syntax" | "demo"> & {
	syntax: string;
	demo?: string;
	sample: { syntax: Sample; demo?: Sample };
};

function build({ syntax, demo, ...rest }: EntryDef): SyntaxEntry {
	return {
		...rest,
		syntax: resolveSample(syntax, englishT),
		demo: demo === undefined ? undefined : resolveSample(demo, englishT),
		sample: { syntax, demo },
	};
}

/**
 * A line of body text that suits each type, so the gallery reads as thirteen
 * worked examples rather than thirteen repetitions of a word. Keyed by type; a
 * type the library adds later falls back to something neutral rather than
 * breaking the build.
 */
const CALLOUT_BODIES: Record<string, string> = {
	note: msg("Worth knowing, but not urgent."),
	tip: msg("A better way to do the same thing."),
	warning: msg("Check this before you continue."),
	abstract: msg("The short version, up front."),
	info: msg("Background you may want."),
	todo: msg("Still outstanding."),
	success: msg("That worked as intended."),
	question: msg("Something worth asking."),
	failure: msg("That did not work."),
	danger: msg("This cannot be undone."),
	bug: msg("A known problem, not yet fixed."),
	example: msg("Here is one, concretely."),
	quote: msg("Said better by someone else."),
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
const CALLOUT_GALLERY: readonly EntryDef[] = Object.entries(defaultConfig.types)
	.filter(([, value]) => typeof value === "object")
	.map(([type]) => ({
		id: `callout-${type}`,
		category: msg("Callouts"),
		label: type,
		// The type identifier is the keyword the user types and the demo title is
		// the name -> icon -> colour mapping, so both stay English.
		syntax: (t: Translate) => `> [!${type}] ${t(TITLE)}\n> ${t(BODY)}`,
		demo: (t: Translate) =>
			`> [!${type}] ${type}\n> ${t(CALLOUT_BODIES[type] ?? CALLOUT_FALLBACK)}`,
		block: true as const,
		hideTemplate: true as const,
		keywords: ["callout", "admonition", "aside", "banner"],
	}));

/** Shown once, prominently, above a category whose rows all share one format. */
const CATEGORY_INTROS: Record<
	string,
	{ syntax?: Sample; note: string; link?: { href: string; label: string } }
> = {
	Headings: {
		// Deliberately worded as convention, because that is what it is: WCAG
		// requires headings be descriptive and their relationships programmatically
		// determinable (SC 1.3.1, 2.4.6) but does not forbid skipping levels, and
		// the HTML5 outline algorithm that would have given multiple <h1>s meaning
		// was never implemented and was dropped from the spec in 2022. What remains
		// true is that the SEQUENCE is what screen readers and our own Outline panel
		// read, so a gap in it is a gap in the outline.
		note: msg(
			"Every heading becomes a line in the Outline panel, which is generated from these. Step down one level at a time; jumping ## to #### leaves a gap in it. By convention # is the note title, which your filename already gives you, so most notes start at ##.",
		),
	},
	Callouts: {
		syntax: (t) => `> [!type] ${t(TITLE)}\n> ${t("Body text.")}`,
		note: msg("Swap `type` for any name below. The title is optional."),
	},
	Math: {
		// The one category whose syntax is a doorway to an entire other language.
		// Two rows can show WHERE math goes but not what can go in it, and the
		// honest answer — a large subset of LaTeX, not all of it — is only useful
		// alongside the list of what made the cut. Hence a real outbound link,
		// unlike the Links section's examples, which deliberately point at us.
		note: msg(
			"Formulas are written in LaTeX and typeset by KaTeX. Single dollar signs keep one in the flow of a sentence; a pair on their own lines centres it as a block. KaTeX covers a large subset of LaTeX rather than all of it, so if a command renders as red source text, it is not supported.",
		),
		link: {
			href: "https://ashki23.github.io/markdown-latex.html#latex",
			label: msg("LaTeX syntax reference"),
		},
	},
};

/**
 * The catalogue. The panel reads it through `filterSyntax` / `groupByCategory`
 * rather than directly; it is exported for the tests that assert invariants
 * across EVERY entry (chiefly the TRUTHFULNESS RULE above — that each one
 * round-trips through NoteView). Not dead, and not a second read path.
 */
const ENTRY_DEFS: readonly EntryDef[] = [
	// ── Text ────────────────────────────────────────────────────────────────
	{
		id: "bold",
		category: msg("Text"),
		label: msg("Bold"),
		syntax: (t) => `**${t("Bold text")}**`,
		keywords: ["strong", "emphasis"],
		templateLed: true,
	},
	{
		id: "italic",
		category: msg("Text"),
		label: msg("Italic"),
		syntax: (t) => `*${t("Italic text")}*`,
		keywords: ["emphasis", "em"],
		templateLed: true,
	},
	{
		id: "bold-italic",
		category: msg("Text"),
		label: msg("Bold italic"),
		syntax: (t) => `***${t("Bold italic text")}***`,
		keywords: ["strong", "emphasis"],
		templateLed: true,
	},
	{
		id: "strikethrough",
		category: msg("Text"),
		label: msg("Strikethrough"),
		syntax: (t) => `~~${t("Struck through")}~~`,
		keywords: ["strike", "delete", "gfm"],
		templateLed: true,
	},
	{
		id: "inline-code",
		category: msg("Text"),
		label: msg("Inline code"),
		syntax: (t) => `\`${t("inline code")}\``,
		blurb: msg("No formatting is applied inside."),
		keywords: ["monospace", "backtick"],
		templateLed: true,
	},
	{
		// Sits directly under inline code on purpose: they are the two ways to
		// stop a mark from being a mark, and knowing only the second one is why
		// people end up wrapping a lone asterisk in backticks and getting a grey
		// chip they did not want.
		//
		// This row is the one place a template and its result differ VISIBLY in
		// the same characters, which is the whole lesson — you type two more
		// characters than you see.
		id: "escape",
		category: msg("Text"),
		label: msg("Escape a mark"),
		syntax: (t) => `\\*${t("not italic")}\\*`,
		blurb: msg(
			"A backslash makes the next punctuation mark literal, so it shows up instead of formatting. Works on any of them: \\* \\_ \\# \\` \\[ \\] and the rest.",
		),
		keywords: ["escape", "backslash", "literal", "verbatim", "asterisk", "underscore", "raw"],
		templateLed: true,
		link: {
			href: "https://daringfireball.net/projects/markdown/syntax#backslash",
			label: msg("Which characters can be escaped"),
		},
	},

	// ── Structure ───────────────────────────────────────────────────────────
	// One row per level. Reading down them shows the size ladder AND a real
	// document outline, which is what a prose blurb saying "levels 1-6" could
	// never do — and each level is separately insertable.
	{
		id: "heading-1",
		category: msg("Headings"),
		label: msg("Heading 1"),
		syntax: (t) => `# ${t("Heading 1")}`,
		block: true,
		keywords: ["title", "h1", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-2",
		category: msg("Headings"),
		label: msg("Heading 2"),
		syntax: (t) => `## ${t("Heading 2")}`,
		block: true,
		keywords: ["title", "h2", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-3",
		category: msg("Headings"),
		label: msg("Heading 3"),
		syntax: (t) => `### ${t("Heading 3")}`,
		block: true,
		keywords: ["title", "h3", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-4",
		category: msg("Headings"),
		label: msg("Heading 4"),
		syntax: (t) => `#### ${t("Heading 4")}`,
		block: true,
		keywords: ["title", "h4", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-5",
		category: msg("Headings"),
		label: msg("Heading 5"),
		syntax: (t) => `##### ${t("Heading 5")}`,
		block: true,
		keywords: ["title", "h5", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "heading-6",
		category: msg("Headings"),
		label: msg("Heading 6"),
		syntax: (t) => `###### ${t("Heading 6")}`,
		block: true,
		keywords: ["title", "h6", "toc", "outline", "section"],
		templateLed: true,
	},
	{
		id: "bullet-list",
		category: msg("Structure"),
		label: msg("Bullet list"),
		syntax: (t) => `- ${t("Bullet item")}`,
		block: true,
		keywords: ["unordered", "ul"],
		templateLed: true,
	},
	{
		id: "numbered-list",
		category: msg("Structure"),
		label: msg("Numbered list"),
		syntax: (t) => `1. ${t("Numbered item")}`,
		block: true,
		keywords: ["ordered", "ol"],
		templateLed: true,
	},
	{
		id: "task-list",
		category: msg("Structure"),
		label: msg("Task list"),
		// Both states in the template, so the left column shows the ONE character
		// that distinguishes them. `demo` would split what is inserted from what is
		// rendered for no gain here — the template already reads as an example.
		syntax: (t) => `- [ ] ${t("Unchecked item")}\n- [x] ${t("Checked item")}`,
		block: true,
		keywords: ["checkbox", "todo", "checklist", "gfm"],
		templateLed: true,
	},
	{
		id: "blockquote",
		category: msg("Structure"),
		label: msg("Blockquote"),
		syntax: (t) => `> ${t("Quoted text")}`,
		block: true,
		keywords: ["quote", "cite"],
		templateLed: true,
	},
	// Three near-identical rows rather than one row with a "nest with >>" blurb.
	// Depth is drawn — one rail per level — so three stacked previews show the
	// ladder at a glance, which is the thing a sentence has to describe badly.
	{
		id: "blockquote-nested",
		category: msg("Structure"),
		label: msg("Nested quote"),
		syntax: (t) => `>> ${t("Nested once")}`,
		block: true,
		keywords: ["quote", "cite", "nest", "nested", "depth"],
		templateLed: true,
	},
	{
		id: "blockquote-nested-twice",
		category: msg("Structure"),
		label: msg("Twice-nested quote"),
		syntax: (t) => `>>> ${t("Nested twice")}`,
		block: true,
		keywords: ["quote", "cite", "nest", "nested", "depth"],
		templateLed: true,
	},
	{
		id: "rule",
		category: msg("Structure"),
		// "Section divider" over "Horizontal rule": the label has to say what the
		// thing is FOR, because the rendered line alone tells you nothing. The
		// technical names stay searchable via keywords.
		label: msg("Section Divider"),
		syntax: "---",
		templatePrelude: [(t) => t(ABOVE_DIVIDER), ""],
		templatePostlude: [(t) => t(BELOW_DIVIDER)],
		// Character-for-character the template above: blank line before the dashes,
		// none after. The specimen has to BE the template, or the row teaches one
		// spacing and demonstrates another.
		//
		// The surrounding prose is also load-bearing for a second reason: NoteView
		// strips frontmatter, which swallows a leading "---" as a frontmatter
		// delimiter and previews an empty box.
		demo: (t) => `${t(ABOVE_DIVIDER)}\n\n---\n${t(BELOW_DIVIDER)}`,
		// No blurb. The blank-line rule used to be spelled out here; the template's
		// ghost line now SHOWS it, and the sentence beside it was saying the same
		// thing a second time.
		block: true,
		framed: true,
		keywords: ["divider", "hr", "separator", "break", "horizontal", "rule", "line"],
	},
	{
		id: "table",
		category: msg("Structure"),
		label: msg("Table"),
		// No separate `demo` here, unlike the other block entries: a table's
		// column widths, alignment and header shading only make sense next to the
		// pipes that produced them, so the specimen has to BE the template. It is
		// still a fine thing to drop at a caret — a two-column starter you edit.
		// Self-describing, like the Text rows: each column is NAMED for the
		// alignment its divider marker sets, so the specimen demonstrates all three
		// markers instead of a sentence listing them.
		syntax: (t) =>
			`| ${t("Left")} | ${t("Center")} | ${t("Right")} |\n| :--- | :---: | ---: |\n| ${t(CELL)} | ${t(CELL)} | ${t(CELL)} |`,
		blurb: msg(
			"The divider row sets each column's alignment. Right-click a table in a note to insert or delete rows and columns.",
		),
		block: true,
		keywords: ["grid", "columns", "gfm"],
	},
	{
		id: "footnote",
		category: msg("Structure"),
		label: msg("Footnote"),
		syntax: (t) => `${t("Claim.")}[^1]\n\n[^1]: ${t("Source.")}`,
		demo: (t) => `${t("Shipped on time.")}[^1]\n\n[^1]: ${t("For a generous value of on time.")}`,
		// Reading view renders this via remark-gfm. The EDITOR does not:
		// @atomic-editor/editor has no footnote support at all — no entry in its
		// inline class map, no hide rule — so `[^1]` stays literal in Edit and Raw.
		// It is the one syntax in this reference that previews but does not render
		// where you are typing, so the blurb has to say so.
		blurb: msg(
			"Numbered automatically, with a link back. Reading view only — the editor leaves [^1] as text.",
		),
		block: true,
		keywords: ["citation", "reference", "gfm"],
	},

	// ── Links & embeds ──────────────────────────────────────────────────────
	{
		id: "wikilink",
		category: msg("Links"),
		label: msg("Wikilink"),
		syntax: (t) => `[[${t(WIKI_TARGET)}]]`,
		templateLed: true,
		keywords: ["internal", "backlink", "obsidian", "link"],
	},
	{
		id: "wikilink-alias",
		category: msg("Links"),
		label: msg("Wikilink with alias"),
		// Same note as the row above, so the pair reads as one idea; the alias is a
		// realistic shorthand rather than the word "alias".
		syntax: (t) => `[[${t(WIKI_TARGET)}|${t("the runbook")}]]`,
		blurb: msg("The pipe sets the display text."),
		templateLed: true,
		keywords: ["internal", "pipe", "obsidian", "link"],
	},
	{
		id: "link",
		category: msg("Links"),
		label: msg("External link"),
		syntax: (t) => `[${t("Engram docs")}](https://engram.page/docs)`,
		templateLed: true,
		keywords: ["url", "href", "hyperlink", "external", "link"],
	},
	{
		id: "image",
		category: msg("Links"),
		label: msg("Image by URL"),
		// The placeholder says what alt text is FOR. "alt" is jargon that teaches
		// nobody, and this string is what lands in the note, so it should read as
		// an instruction to replace.
		// No blurb: the placeholder text explains itself, and "any image on the
		// web" only restated the URL sitting right beside it.
		syntax: (t) => `![${t("text if it can't load")}](https://example.com/photo.png)`,
		renderable: false,
		templateLed: true,
		keywords: ["picture", "img", "photo", "link"],
	},
	{
		id: "embed",
		category: msg("Links"),
		label: msg("Embed attachment"),
		syntax: "![[diagram.png]]",
		blurb: msg("A file from your vault."),
		renderable: false,
		templateLed: true,
		keywords: ["attachment", "transclude", "obsidian", "pdf", "embed", "link"],
	},

	...CALLOUT_GALLERY,

	// ── Callouts: fold markers ────────────────────────────────────────────────────────────
	{
		id: "callout-foldable",
		category: msg("Callouts"),
		label: msg("Foldable Callout"),
		syntax: (t) => `> [!tip]- ${t(TITLE)}\n> ${t(BODY)}`,
		// No demo, and not previewed: @portaljs/remark-callouts does not consume
		// the fold marker, so remark parses the "- Title" that follows as a BULLET
		// LIST and the title renders as `<ul><li>`. Showing that would teach the
		// wrong thing. It does fold correctly in Obsidian, which is why the entry
		// stays — but the blurb has to say where it works.
		blurb: msg(
			"Obsidian only: - starts folded, + starts open. The web viewer shows the marker as a bullet.",
		),
		renderable: false,
		block: true,
		keywords: ["collapse", "fold", "details", "accordion"],
	},

	// ── Code ────────────────────────────────────────────────────────────────
	{
		id: "code-fence",
		category: msg("Code"),
		label: msg("Code Block"),
		// The BARE fence was missing entirely — the section documented only the
		// language-tagged form, so the base syntax everyone reaches for first was
		// nowhere in the reference.
		syntax: (t) => `\`\`\`\n${t("Plain code, no highlighting")}\n\`\`\``,
		block: true,
		keywords: ["fence", "snippet", "backticks", "preformatted", "pre", "monospace"],
	},
	{
		id: "code-fence-lang",
		category: msg("Code"),
		label: msg("Highlighted Code Block"),
		// Template and preview are the same string here, as with the table and the
		// diagram: `code` above a rendered `const total = items.length;` left the
		// reader matching one to the other for no gain.
		syntax: "```ts\nconst total = items.length;\n```",
		blurb: msg(
			"Many languages are supported. Name the type straight after the opening fence. It is usually the file extension: ts for TypeScript, js for JavaScript.",
		),
		block: true,
		keywords: ["fence", "syntax", "highlight", "snippet", "language", "ts", "js", "elixir"],
	},
	{
		id: "mermaid",
		category: msg("Code"),
		label: msg("Mermaid Diagram"),
		// No separate `demo`, for the same reason as the table: a diagram's shape
		// is the whole lesson, and `A --> B` above a rendered Edit → Sync → Vault
		// flow left the reader to guess which part of the source produced which
		// box. The template IS the diagram you see.
		syntax: "```mermaid\ngraph LR\n  Edit --> Sync --> Vault\n```",
		blurb: msg("Flowchart, sequence, class and state diagrams."),
		link: {
			href: "https://mermaid.ai/open-source/intro/syntax-reference.html",
			label: msg("Mermaid syntax reference"),
		},
		block: true,
		keywords: ["diagram", "graph", "flowchart", "chart", "uml"],
	},

	// ── Math ────────────────────────────────────────────────────────────────
	{
		id: "math-inline",
		category: msg("Math"),
		label: msg("Inline Math"),
		syntax: "$E = mc^2$",
		// Blurbs dropped from both Math rows: the category intro above them now
		// carries the inline-vs-block distinction, and repeating "KaTeX" on each
		// row said it three times on one screen.
		keywords: ["katex", "latex", "tex", "equation", "formula"],
		templateLed: true,
	},
	{
		id: "math-block",
		category: msg("Math"),
		label: msg("Block Math"),
		syntax: "$$\n\\int_0^1 x^2 \\, dx = \\frac{1}{3}\n$$",
		block: true,
		keywords: ["katex", "latex", "tex", "equation", "display"],
	},

	// ── Properties ──────────────────────────────────────────────────────────
	{
		id: "frontmatter",
		category: msg("Properties"),
		label: msg("Frontmatter"),
		syntax: (t) => `---\ntitle: ${t("My note")}\ntags: [${t("idea")}, ${t("draft")}]\n---`,
		blurb: msg("Must be the very first thing in the note. Shows up as note properties."),
		block: true,
		renderable: false,
		keywords: ["yaml", "metadata", "properties", "tags", "header"],
	},
	{
		id: "tag",
		category: msg("Properties"),
		label: msg("Tag"),
		syntax: (t) => `#${t("topic")}`,
		blurb: msg("Also settable via the tags frontmatter key."),
		keywords: ["hashtag", "label", "category"],
		templateLed: true,
	},
];

const SYNTAX_ENTRIES: readonly SyntaxEntry[] = ENTRY_DEFS.map(build);

/** What Insert drops at the caret, in the reader's language. */
export function entrySyntax(entry: SyntaxEntry, t: Translate = englishT): string {
	return resolveSample(entry.sample.syntax, t);
}

/** What the preview renders: the worked example if there is one, else the template. */
export function previewSource(entry: SyntaxEntry, t: Translate = englishT): string {
	return resolveSample(entry.sample.demo ?? entry.sample.syntax, t);
}

/**
 * Case-insensitive AND-match across every searchable field: all whitespace-
 * separated terms must appear somewhere in the entry. "block math" and
 * "math block" therefore both find block math, which a single substring test
 * on a joined string would not do reliably.
 */
export function filterSyntax(
	query: string,
	// Also match the words the user is reading, not only the English source.
	t: Translate = englishT,
): readonly SyntaxEntry[] {
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
			t(entry.label),
			t(entry.category),
			entrySyntax(entry, t),
			entry.blurb ? t(entry.blurb) : "",
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

export type { Sample, SyntaxEntry };
export { CATEGORY_INTROS, resolveSample, SYNTAX_ENTRIES };

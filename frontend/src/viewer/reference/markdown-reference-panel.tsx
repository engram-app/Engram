import hljs from "highlight.js/lib/common";
import { ArrowRight, ChevronRight, Plus } from "lucide-react";
import { useId, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useActiveEditor } from "../editor/active-editor-context";
import { insertSnippet } from "../editor/format-commands";
import NoteView from "../note-view";
import {
	CATEGORY_INTROS,
	filterSyntax,
	groupByCategory,
	previewSource,
	type SyntaxEntry,
} from "./markdown-syntax";

// Searchable catalogue of the markdown Engram renders, with one-click insertion
// into the open note.
//
// The preview is rendered by the REAL NoteView, not a lookalike. Seeing the
// callout is the point — nobody learns "> [!tip]" from the source alone — and
// reusing the app's own renderer means this panel cannot quietly document
// syntax the app stopped supporting.
//
// Categories are native <details> accordions, and a closed one renders NO
// children. That conditional matters: React mounts <details> children whether
// or not the element is open — only the browser hides them — so without it every
// one of the ~29 entries spins up a full remark/KaTeX/mermaid pipeline the
// moment the panel opens.

// NO prose-sm. The previews render at the document's own scale so a callout,
// heading or table in this panel is pixel-identical to the same thing in a
// note — that parity is the whole point of rendering through NoteView rather
// than a lookalike, and a smaller scale quietly broke it.
//
// The `[&_…]` rules only trim the OUTER gutter (Typography's ~1em on the first
// and last block, plus Mermaid's own my-4). Spacing BETWEEN blocks is left
// alone, so multi-part snippets keep the document's rhythm too.
// [&_a]:pointer-events-none — previews should LOOK like the real thing without
// behaving like it. A wikilink here points at a note that does not exist and an
// external link would navigate away mid-edit. Done in CSS rather than a click
// handler so there is no a11y rule to suppress and the text stays selectable.
// [&_li]:my-0 drops Typography's 0.5em list-item margins. Prose spacing is
// tuned for a full document; inside a two-line example it put a 36px pitch on
// the rendered side against the template's 20px, so the two columns of the same
// example visibly disagreed about where line two starts.
// [&_blockquote:not(.callout)]:my-0 rather than relying on the `.prose>` resets
// below: remark-callouts wraps a plain blockquote in an unclassed <div>, so the
// quote is a GRANDchild of .prose and those first/last-child rules never reach
// it. Its 1.6em margins survived and made every quote row twice the height of
// its neighbours. Callouts are excluded — they keep their own spacing.
// [&_hr]:mb-0 [&_hr+*]:mt-0 makes the divider specimen mirror its own template:
// a blank line above the dashes, none below, so the gaps you see are the gaps
// you typed. Typography's 3em hr margin plus the next paragraph's own margin
// opened a gap under the rule that the template does not have.
const PREVIEW =
	"[&_a]:pointer-events-none [&_.mermaid]:my-0 [&_li]:my-0 [&_blockquote:not(.callout)]:my-0 [&_hr]:mb-0 [&_hr+*]:mt-0 [&_.prose>:first-child]:mt-0 [&_.prose>:last-child]:mb-0";

// text-sm: a middle ground. At 11px a template read as a different document
// from the 16px result beside it; at the document's full 16px the longer
// templates wrapped onto a second line. 14px keeps them legible and on one.
const SOURCE =
	"whitespace-pre-wrap break-words bg-muted/50 px-2 py-1 font-mono text-sm text-muted-foreground";

// One class for every row-level heading, so a row that needs a prominent title
// cannot style it slightly differently from the next one. Sentence-weight and
// not uppercase: the category <summary> above it owns that treatment, and two
// headers styled alike is what made sections hard to find in the first place.
const ROW_HEADING = "font-semibold text-foreground text-sm";

/**
 * A REAL outbound link, unlike the inert anchors inside previews — this one is
 * the point. Its own line rather than trailing the prose, so it reads as "go
 * here for more" instead of disappearing into the sentence.
 */
function RefLink({ link }: { link?: { href: string; label: string } }) {
	if (!link) {
		return null;
	}
	return (
		<a
			href={link.href}
			target="_blank"
			rel="noreferrer"
			className="mt-1.5 inline-block text-xs underline underline-offset-2 hover:text-foreground"
		>
			{link.label}
		</a>
	);
}

// ```lang / body / ``` — the only template shape whose body is another language.
const FENCE_TEMPLATE = /^```(?<lang>\w+)\n(?<body>[\s\S]*)\n```$/u;

/**
 * A template block, with a fenced body highlighted in its own language.
 *
 * The code-fence rows show the SAME string twice: once as the template you
 * type, once as the result. Leaving the template flat grey beside a coloured
 * result read as if the highlighting were something the panel did rather than
 * something the editor does to your source. The fence markers stay plain, since
 * they are markdown rather than code.
 *
 * Anything that is not a fence, or is tagged with a language highlight.js does
 * not know (```mermaid), falls through untouched.
 */
function TemplateSource({ syntax }: { syntax: string }) {
	const match = FENCE_TEMPLATE.exec(syntax);
	const lang = match?.groups?.lang;
	if (!(match && lang && hljs.getLanguage(lang))) {
		return <>{syntax}</>;
	}
	// Bound to consts rather than inlined as JSX string literals: the closing
	// fence is a bare "\n```", which biome's consistent-curly-braces rule rejects
	// in braces and which cannot be written as JSX text without losing the break.
	const openFence = `\`\`\`${lang}\n`;
	const closeFence = "\n```";
	return (
		<>
			{openFence}
			{/* hljs escapes the source it highlights, and the input is our own static
			    catalogue rather than note content, so nothing user-authored reaches
			    innerHTML here. */}
			<span
				dangerouslySetInnerHTML={{
					__html: hljs.highlight(match.groups?.body ?? "", { language: lang }).value,
				}}
			/>
			{closeFence}
		</>
	);
}

/** A rendered example. See PREVIEW for why links here are inert. */
function Preview({ entry, className = "" }: { entry: SyntaxEntry; className?: string }) {
	return (
		<span className={`${PREVIEW} ${className}`}>
			<NoteView content={previewSource(entry)} tags={[]} />
		</span>
	);
}

function InsertButton({ entry, canInsert }: { entry: SyntaxEntry; canInsert: boolean }) {
	const { getView } = useActiveEditor();
	return (
		<Button
			variant="ghost"
			size="icon-sm"
			disabled={!canInsert}
			onClick={() => {
				const view = getView();
				if (view) {
					insertSnippet(view, entry.syntax, { block: entry.block });
				}
			}}
			aria-label={`Insert ${entry.label}`}
			title={canInsert ? `Insert ${entry.label} at the cursor` : "Open a note to insert"}
			// self-stretch + h-auto: the hit area spans the row's full height rather
			// than being a small square floating at the top, so the button is easy to
			// aim at next to a tall callout or table.
			//
			// Revealed on hover/focus so a long list isn't a wall of buttons, but
			// never hidden from keyboards or touch (where hover does not exist).
			className="h-auto w-9 shrink-0 self-stretch rounded-none opacity-0 transition-opacity focus-visible:opacity-100 disabled:opacity-0 group-hover:opacity-100 [@media(hover:none)]:opacity-100"
		>
			<Plus className="size-4" />
		</Button>
	);
}

/**
 * Everything fits on one line — template AND result. That is the real question
 * for layout; `block` only ever meant "insertion needs newlines synthesized".
 * Keying off shape is what lets the six heading levels read as a ladder of
 * one-line rows rather than six stacked blocks.
 */
function fitsOneLine(entry: SyntaxEntry): boolean {
	return !(entry.syntax.includes("\n") || previewSource(entry).includes("\n"));
}

// Self-evident syntax gets ONE line: name, template, result. Stacking a preview
// box, a source box and a blurb around `**text**` padded the simple entries out
// to justify the complex ones.
function InlineRow({ entry, canInsert }: { entry: SyntaxEntry; canInsert: boolean }) {
	return (
		<li className="group flex items-stretch border-border border-b last:border-b-0">
			<span className="block min-w-0 flex-1 px-3 py-1.5">
				<p className="flex items-center gap-2">
					<span
						className="w-24 shrink-0 truncate font-medium text-foreground text-xs"
						title={entry.label}
					>
						{entry.label}
					</span>
					<code
						className="shrink-0 font-mono text-muted-foreground text-sm"
						title="Inserted at the cursor"
					>
						{entry.syntax}
					</code>
					{entry.renderable === false ? null : (
						<>
							<ArrowRight className="size-3 shrink-0 text-muted-foreground/50" />
							<Preview entry={entry} className="block min-w-0 flex-1 overflow-hidden" />
						</>
					)}
				</p>
				{/* Rendered, not dropped. An earlier version of this row showed a blurb
			    only for non-previewable entries, which silently hid genuinely useful
			    notes like "No formatting is applied inside" on inline code. Rows
			    without a blurb stay a single line. */}
				{entry.blurb ? <p className="mt-0.5 text-muted-foreground text-xs">{entry.blurb}</p> : null}
			</span>
			<InsertButton entry={entry} canInsert={canInsert} />
		</li>
	);
}

/**
 * A callout-gallery row: the rendered callout and nothing else. No label — the
 * callout's own title already IS the type name, so a label above it said the
 * same word twice — and no template, because the format is stated once above
 * the whole section. The Insert button sits inline beside it rather than on a
 * heading row of its own.
 */
function GalleryRow({ entry, canInsert }: { entry: SyntaxEntry; canInsert: boolean }) {
	return (
		<li className="group flex items-stretch border-border border-b last:border-b-0">
			<Preview entry={entry} className="block min-w-0 flex-1 overflow-hidden px-3 py-1" />
			<InsertButton entry={entry} canInsert={canInsert} />
		</li>
	);
}

/**
 * Template-led row: syntax on the left, result on the right, no label.
 *
 * Used where the rendered output does NOT tell entries apart. Every link
 * variant renders as the same blue link, so `[[ ]]` versus `[](  )` is the only
 * thing that distinguishes them — putting the template first makes the column
 * scannable, and a "Wikilink" label would only restate the brackets in words.
 * The template column is a percentage so the arrows stay aligned down the
 * section at any panel width, and it wraps rather than truncating: a syntax
 * reference that hides half the syntax is worse than a taller row.
 */
function TemplateRow({ entry, canInsert }: { entry: SyntaxEntry; canInsert: boolean }) {
	const previewable = entry.renderable !== false;
	// Nothing to show on the right? Then the template gets the whole row instead
	// of being squeezed into its column — that is what kept the long image
	// template wrapping onto a second line for no reason.
	const showsResult = previewable || Boolean(entry.blurb);
	return (
		<li className="group flex items-stretch border-border border-b last:border-b-0">
			<span className="block min-w-0 flex-1 px-3 py-1.5">
				{/* items-center, and the template sized to its content rather than a
				    fixed 45% column: the column aligned the arrows but left a wide dead
				    gap after short templates like [[Note name]]. */}
				<span className="flex items-center gap-2">
					<code
						// whitespace-pre-wrap: a multi-line template (the task list shows an
						// unchecked and a checked item) would otherwise collapse onto one
						// line — <code> does not preserve newlines on its own.
						//
						// leading-7 matches the prose line-height on the rendered side, so
						// multi-line templates track their result line for line. Single-line
						// rows are unaffected: the preview already sets the row height.
						// The template is the thing being documented, so it keeps its width
						// while the result gives way — but it must still wrap once the result
						// has nothing left to give, rather than push the result off the row.
						// The preview's much larger shrink factor is what defers that to last.
						//
						// min-w-MIN, not min-w-0: with a zero floor the box shrank straight
						// past its own text to 0px and the template overflowed invisibly
						// instead of wrapping. A min-content floor is what forces the wrap.
						// A max-w (the earlier approach) wrapped it at a fixed fraction even
						// with room to spare.
						// [overflow-wrap:anywhere] rather than break-words. They look alike,
						// but only `anywhere` counts toward MIN-CONTENT width. With
						// break-words a template containing a URL reported a min-content of
						// the whole unbreakable URL, so min-w-min pinned the box at that
						// width and it shoved the preview out of the row instead of wrapping.
						className={`whitespace-pre-wrap font-mono text-foreground text-sm leading-7 [overflow-wrap:anywhere] ${
							showsResult ? "min-w-min shrink" : "min-w-0 flex-1"
						}`}
					>
						{entry.syntax}
					</code>
					{previewable ? (
						<>
							<ArrowRight className="size-3 shrink-0 text-muted-foreground/50" />
							{/* No flex-1. That is `flex: 1 1 0%`, which claims ALL the leftover
							    room whatever the content is, so a two-word rendered link
							    reserved half the row and forced the template to wrap beside a
							    band of empty space.
							    Instead: sized by content, with a large shrink factor so it is
							    the FIRST thing to give way, and min-w-min as the floor so it
							    stops at its own longest word rather than collapsing to nothing
							    and sliding out of the row. Past that point the template wraps.
							    (min-w-min, not min-w-0, precisely because overflow-hidden
							    would otherwise let it shrink to zero.) */}
							<Preview entry={entry} className="block min-w-min shrink-[99] overflow-hidden" />
						</>
					) : entry.blurb ? (
						<span className="min-w-0 flex-1 text-muted-foreground text-xs">{entry.blurb}</span>
					) : null}
				</span>
				{previewable && entry.blurb ? (
					<span className="mt-0.5 block text-muted-foreground text-xs">{entry.blurb}</span>
				) : null}
			</span>
			<InsertButton entry={entry} canInsert={canInsert} />
		</li>
	);
}

/**
 * Surrounding lines in a framed row's template. Block spans rather than embedded
 * "\n": inside a <pre> they break the line just the same, and it keeps each line
 * addressable for styling.
 */
function ContextLines({ lines }: { lines?: readonly string[] }) {
	return lines?.map((line) =>
		line === "" ? (
			// The rule the divider teaches is about a line with nothing on it.
			// Rendering that blank line as a visible ghost shows the shape; prose
			// could only assert it.
			<span key="blank" className="block text-muted-foreground/50 italic">
				leave this line empty
			</span>
		) : (
			<span key={line} className="block text-foreground">
				{line}
			</span>
		),
	);
}

/**
 * Heading, template, then the rendered result: the reading order that matches
 * how you actually use the row — name it, see what to type, see what you get.
 *
 * Every entry reaching here has a multi-line template, so the template always
 * gets a block of its own; the single-line ones are all InlineRow or
 * TemplateRow. `framed` adds a border around the preview, for the one result
 * that is not self-evident — a lone horizontal rule read as the panel's own row
 * separator rather than as the specimen.
 */
function BlockRow({ entry, canInsert }: { entry: SyntaxEntry; canInsert: boolean }) {
	return (
		<li className="group flex items-stretch border-border border-b last:border-b-0">
			<span className="block min-w-0 flex-1 px-3 py-2">
				<p className={`mb-1 ${ROW_HEADING}`}>{entry.label}</p>

				{/* Blurb sits directly under the heading, as a subtitle. Trailing it
			    after the source made it read as a footer nobody looks at, and it is
			    the one part of the row that cannot be inferred from the preview.
			    text-foreground, not muted: at muted/xs it read as a footnote you
			    skip. Regular weight keeps it under the heading. */}
				{entry.blurb ? <p className="mb-1.5 text-foreground text-xs">{entry.blurb}</p> : null}

				{/* Above the template, not trailing the row: a link to someone else's
				    grammar is context for reading what follows, and at the bottom it
				    sat below a tall preview where nobody would scroll to find it. */}
				{entry.link ? (
					<p className="mb-1.5">
						<RefLink link={entry.link} />
					</p>
				) : null}

				{/* The TEMPLATE — exactly what Insert drops at the caret. bg-muted/50
			    rather than the full token: a rendered fence uses --muted itself, so a
			    solid box directly above one read as a second identical panel. */}
				<pre className={`${SOURCE} ${entry.framed ? "mb-3" : "mb-1.5"}`}>
					<ContextLines lines={entry.templatePrelude} />
					{/* The payload specifically — the context lines around it are not
					    inserted, which is why the title sits here, not on the block. */}
					<span title="Inserted at the cursor" className="block text-foreground">
						<TemplateSource syntax={entry.syntax} />
					</span>
					<ContextLines lines={entry.templatePostlude} />
				</pre>

				{entry.renderable === false ? null : (
					// Unframed, the preview gets no border, background or padding of its
					// own. Each one already carries its own surface — a fence is grey, a
					// callout is tinted, a table has rules — so an outer box left that
					// surface inset inside another, visibly failing to fill it (worst on
					// Mermaid, whose centred SVG sat in a grey band floating in a box).
					<figure
						className={`overflow-hidden ${entry.framed ? "border border-border px-3 py-2" : ""}`}
					>
						<Preview entry={entry} className="block" />
					</figure>
				)}
			</span>
			<InsertButton entry={entry} canInsert={canInsert} />
		</li>
	);
}

export default function MarkdownReferencePanel() {
	const [query, setQuery] = useState("");
	// Only the first category starts open — the whole point of the accordions is
	// that the panel does not open as a wall of 29 examples.
	const [openCategories, setOpenCategories] = useState<ReadonlySet<string>>(new Set(["Text"]));
	const { hasEditor } = useActiveEditor();
	const searchId = useId();

	const groups = useMemo(() => groupByCategory(filterSyntax(query)), [query]);
	const searching = query.trim() !== "";

	const setOpen = (category: string, open: boolean) =>
		setOpenCategories((prev) => {
			if (prev.has(category) === open) {
				return prev;
			}
			const next = new Set(prev);
			if (open) {
				next.add(category);
			} else {
				next.delete(category);
			}
			return next;
		});

	return (
		<section className="flex h-full min-h-0 flex-col" aria-label="Markdown reference">
			<search className="shrink-0 border-border border-b px-3 py-2">
				<label className="sr-only" htmlFor={searchId}>
					Search markdown syntax
				</label>
				<input
					id={searchId}
					type="search"
					value={query}
					onChange={(e) => setQuery(e.target.value)}
					placeholder="Search syntax…"
					className="w-full rounded-md border border-border bg-background px-2 py-1 text-sm outline-none placeholder:text-muted-foreground focus-visible:ring-2 focus-visible:ring-ring"
				/>
			</search>

			{!hasEditor && (
				<p className="shrink-0 border-border border-b bg-muted/40 px-3 py-1.5 text-muted-foreground text-xs">
					Open a note to insert snippets.
				</p>
			)}

			{/* pr-2.5 matches the Radix scrollbar's own width. Without it the track
			    sits ON TOP of the right-hand column, which put it over the insert
			    buttons — they were centred correctly, they were just half-covered.
			    Padding the Root insets the viewport while leaving the scrollbar
			    (absolutely positioned to the border box) in the gutter it creates. */}
			<ScrollArea className="min-h-0 flex-1 pr-2.5">
				{groups.length === 0 ? (
					<p className="px-3 py-6 text-center text-muted-foreground text-sm">
						No syntax matches “{query}”.
					</p>
				) : (
					groups.map(([category, entries]) => {
						// A search forces every matching section open — hiding the hit the
						// user just searched for behind a closed accordion is useless.
						const open = searching || openCategories.has(category);
						const intro = CATEGORY_INTROS[category];
						return (
							<details
								key={category}
								open={open}
								onToggle={(e) => setOpen(category, e.currentTarget.open)}
								className="group/cat border-border border-b-2"
							>
								{/* sticky: once a section is open you scroll past several tall
								    previews, and without a pinned header you lose track of which
								    category you are in. The solid (not translucent) background is
								    what lets it sit over a rendered preview without smearing. */}
								<summary className="sticky top-0 z-10 flex cursor-pointer list-none items-center gap-1.5 border-border border-y bg-muted px-3 py-2 font-semibold text-foreground text-sm uppercase tracking-wider hover:bg-accent">
									<ChevronRight className="size-4 shrink-0 text-muted-foreground transition-transform group-open/cat:rotate-90" />
									{category}
									<span className="ml-auto rounded-full bg-background px-1.5 py-0.5 font-normal text-[10px] text-muted-foreground tabular-nums tracking-normal">
										{entries.length}
									</span>
								</summary>
								{open ? (
									<>
										{intro ? (
											// One format, stated once and loudly, rather than repeated
											// quietly on all thirteen rows beneath it.
											<section className="border-border border-b bg-muted/30 px-3 py-2.5">
												{intro.syntax ? (
													<pre className="whitespace-pre-wrap break-words font-mono font-semibold text-foreground text-xs">
														{intro.syntax}
													</pre>
												) : null}
												<p className="text-muted-foreground text-xs">{intro.note}</p>
												<RefLink link={intro.link} />
											</section>
										) : null}
										<ul>
											{entries.map((entry) => {
												if (entry.hideTemplate) {
													return <GalleryRow key={entry.id} entry={entry} canInsert={hasEditor} />;
												}
												if (entry.templateLed) {
													return <TemplateRow key={entry.id} entry={entry} canInsert={hasEditor} />;
												}
												return fitsOneLine(entry) ? (
													<InlineRow key={entry.id} entry={entry} canInsert={hasEditor} />
												) : (
													<BlockRow key={entry.id} entry={entry} canInsert={hasEditor} />
												);
											})}
										</ul>
									</>
								) : null}
							</details>
						);
					})
				)}
			</ScrollArea>
		</section>
	);
}

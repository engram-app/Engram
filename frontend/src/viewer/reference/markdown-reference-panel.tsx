import { ArrowRight, ChevronRight, Plus } from "lucide-react";
import { useId, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useActiveEditor } from "../editor/active-editor-context";
import { insertSnippet } from "../editor/format-commands";
import NoteView from "../note-view";
import { filterSyntax, groupByCategory, previewSource, type SyntaxEntry } from "./markdown-syntax";

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

// prose-sm because the shared markdown styles are tuned for an 840px document
// column, not a 300px rail. The `[&_.prose…]` pair strips the ~1em margin
// Typography puts on every block (and Mermaid's own my-4), which was most of the
// dead space, while keeping the rhythm between blocks of a multi-part snippet.
const PREVIEW =
	"prose-sm [&_.mermaid]:my-0 [&_.prose>:first-child]:mt-0 [&_.prose>:last-child]:mb-0";

const SOURCE =
	"whitespace-pre-wrap break-words bg-muted/50 px-2 py-1 font-mono text-[11px] text-muted-foreground";

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
			// Revealed on hover/focus so a long list isn't a wall of buttons, but
			// never hidden from keyboards or touch (where hover does not exist).
			className="shrink-0 opacity-0 transition-opacity focus-visible:opacity-100 disabled:opacity-0 group-hover:opacity-100 [@media(hover:none)]:opacity-100"
		>
			<Plus className="size-4" />
		</Button>
	);
}

// Inline marks are self-evident from their source, so they get ONE line:
// name, template, result. Stacking a preview box, a source box and a blurb
// around `**text**` padded the simple entries out to justify the complex ones.
function InlineRow({ entry, canInsert }: { entry: SyntaxEntry; canInsert: boolean }) {
	return (
		<li className="group flex items-center gap-2 border-border/60 border-b px-3 py-1.5 last:border-b-0">
			<span className="w-20 shrink-0 truncate font-medium text-foreground text-xs">
				{entry.label}
			</span>
			<code
				className="shrink-0 font-mono text-[11px] text-muted-foreground"
				title="Inserted at the cursor"
			>
				{entry.syntax}
			</code>
			{entry.renderable === false ? (
				<span className="min-w-0 flex-1 truncate text-muted-foreground text-xs">{entry.blurb}</span>
			) : (
				<>
					<ArrowRight className="size-3 shrink-0 text-muted-foreground/50" />
					<span className={`min-w-0 flex-1 overflow-hidden ${PREVIEW}`}>
						<NoteView content={previewSource(entry)} tags={[]} />
					</span>
				</>
			)}
			<InsertButton entry={entry} canInsert={canInsert} />
		</li>
	);
}

function BlockRow({ entry, canInsert }: { entry: SyntaxEntry; canInsert: boolean }) {
	// `block` governs INSERTION (does it need newlines synthesized). Whether the
	// template deserves a block of its own is a separate question, and the answer
	// is just its shape: `---` is as self-evident as `**text**`, so it rides
	// beside the label. Only a multi-line template earns its own <pre>. That drops
	// a full-width row from most of Structure.
	const templateFitsInline = !entry.syntax.includes("\n");

	return (
		<li className="group border-border/60 border-b px-3 py-2 last:border-b-0">
			<p className="mb-1.5 flex items-center gap-2">
				{/* Sentence case, not uppercase: this used to be styled identically to
				    the category header above it — same size, weight, colour and case —
				    so there was no hierarchy to read and sections were easy to lose.
				    The entry label is the quieter of the two now. */}
				<span className="shrink-0 font-medium text-foreground text-xs">{entry.label}</span>
				{templateFitsInline ? (
					<code
						className="min-w-0 flex-1 truncate font-mono text-[11px] text-muted-foreground"
						title="Inserted at the cursor"
					>
						{entry.syntax}
					</code>
				) : (
					<span className="flex-1" />
				)}
				<InsertButton entry={entry} canInsert={canInsert} />
			</p>

			{/* Blurb sits directly under the label, as a subtitle. Trailing it after
			    the source made it read as a footer nobody looks at, and it is the one
			    part of the row that cannot be inferred from the preview. */}
			{entry.blurb ? <p className="mb-1.5 text-muted-foreground text-xs">{entry.blurb}</p> : null}

			{entry.renderable === false ? null : (
				// No border, background or padding of its own. Each preview already
				// carries its own surface — a fence is grey, a callout is tinted, a
				// table has rules — so wrapping it in another box left that surface
				// inset inside an outer one, visibly failing to fill it (worst on
				// Mermaid, whose centred SVG sat in a grey band floating in a white
				// box). The container is gone, so there is nothing left to not fill.
				<figure className={`overflow-hidden ${templateFitsInline ? "" : "mb-1"} ${PREVIEW}`}>
					<NoteView content={previewSource(entry)} tags={[]} />
				</figure>
			)}

			{/* The TEMPLATE, not the worked example above it — this is exactly what
			    Insert drops at the caret. bg-muted/50 rather than the full token: a
			    rendered fence now uses --muted itself, so a solid box directly beneath
			    one read as a second identical panel. */}
			{templateFitsInline ? null : (
				<pre className={SOURCE} title="Inserted at the cursor">
					{entry.syntax}
				</pre>
			)}
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

			<ScrollArea className="min-h-0 flex-1">
				{groups.length === 0 ? (
					<p className="px-3 py-6 text-center text-muted-foreground text-sm">
						No syntax matches “{query}”.
					</p>
				) : (
					groups.map(([category, entries]) => {
						// A search forces every matching section open — hiding the hit the
						// user just searched for behind a closed accordion is useless.
						const open = searching || openCategories.has(category);
						return (
							<details
								key={category}
								open={open}
								onToggle={(e) => setOpen(category, e.currentTarget.open)}
								className="group/cat border-border border-b"
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
									<ul>
										{entries.map((entry) =>
											entry.block ? (
												<BlockRow key={entry.id} entry={entry} canInsert={hasEditor} />
											) : (
												<InlineRow key={entry.id} entry={entry} canInsert={hasEditor} />
											),
										)}
									</ul>
								) : null}
							</details>
						);
					})
				)}
			</ScrollArea>
		</section>
	);
}

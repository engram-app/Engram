import { ChevronRight, Plus } from "lucide-react";
import { useId, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useActiveEditor } from "../editor/active-editor-context";
import { insertSnippet } from "../editor/format-commands";
import NoteView from "../note-view";
import { filterSyntax, groupByCategory, type SyntaxEntry } from "./markdown-syntax";

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

function EntryRow({ entry, canInsert }: { entry: SyntaxEntry; canInsert: boolean }) {
	const { getView } = useActiveEditor();

	const insert = () => {
		const view = getView();
		if (!view) {
			return;
		}
		insertSnippet(view, entry.syntax, { block: entry.block });
	};

	return (
		<li className="group border-border/60 border-b px-3 py-2.5 last:border-b-0">
			<p className="mb-1.5 flex items-center gap-2">
				<span className="min-w-0 flex-1 truncate font-medium text-muted-foreground text-xs uppercase tracking-wide">
					{entry.label}
				</span>
				<Button
					variant="ghost"
					size="icon-sm"
					disabled={!canInsert}
					onClick={insert}
					aria-label={`Insert ${entry.label}`}
					title={canInsert ? `Insert ${entry.label} at the cursor` : "Open a note to insert"}
					// Revealed on hover/focus so a long list isn't a wall of buttons, but
					// never hidden from keyboards or touch (where hover does not exist).
					className="shrink-0 opacity-0 transition-opacity focus-visible:opacity-100 disabled:opacity-0 group-hover:opacity-100 [@media(hover:none)]:opacity-100"
				>
					<Plus className="size-4" />
				</Button>
			</p>

			{entry.renderable === false ? null : (
				// prose-sm: the shared markdown styles are tuned for an 840px document
				// column, not a 300px rail.
				//
				// overflow-hidden, NOT overflow-x-auto: a wide preview (table, mermaid,
				// long fence) would otherwise grow its own native horizontal scrollbar
				// inside the panel's Radix one, and a column of those makes the whole
				// section miserable to scroll. Previews are illustrative — clipping the
				// far edge of a demo table costs nothing.
				<figure className="prose-sm mb-1.5 overflow-hidden rounded border border-border/60 bg-background px-2 py-1.5">
					<NoteView content={entry.syntax} tags={[]} />
				</figure>
			)}

			{/* whitespace-pre-wrap already prevents horizontal overflow — no scroller. */}
			<pre className="whitespace-pre-wrap break-words rounded bg-muted px-2 py-1 font-mono text-[11px] text-muted-foreground">
				{entry.syntax}
			</pre>

			<p className="mt-1 text-muted-foreground text-xs">{entry.blurb}</p>
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
								<summary className="flex cursor-pointer list-none items-center gap-1 px-3 py-1.5 font-medium text-muted-foreground text-xs uppercase tracking-wide hover:bg-muted/40">
									<ChevronRight className="size-3.5 shrink-0 transition-transform group-open/cat:rotate-90" />
									{category}
									<span className="ml-auto text-[10px] tabular-nums opacity-60">
										{entries.length}
									</span>
								</summary>
								{open ? (
									<ul>
										{entries.map((entry) => (
											<EntryRow key={entry.id} entry={entry} canInsert={hasEditor} />
										))}
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

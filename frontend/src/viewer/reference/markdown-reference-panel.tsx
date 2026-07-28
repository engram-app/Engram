import { Plus } from "lucide-react";
import { useId, useMemo, useState } from "react";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useActiveEditor } from "../editor/active-editor-context";
import { insertSnippet } from "../editor/format-commands";
import { filterSyntax, groupByCategory, type SyntaxEntry } from "./markdown-syntax";

// Searchable catalogue of the markdown Engram renders, with one-click insertion
// into the open note. Rendered by the right sidebar, which lives OUTSIDE the
// note page — hence useActiveEditor rather than a prop-drilled editor handle.

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
		<li className="group border-border/60 border-b px-3 py-2 last:border-b-0 hover:bg-muted/40">
			<p className="flex items-center gap-2">
				<span className="min-w-0 flex-1 truncate font-medium text-sm">{entry.label}</span>
				<Button
					variant="ghost"
					size="icon-sm"
					disabled={!canInsert}
					onClick={insert}
					aria-label={`Insert ${entry.label}`}
					title={canInsert ? `Insert ${entry.label} at the cursor` : "Open a note to insert"}
					// Revealed on hover/focus so 30 rows aren't 30 competing buttons,
					// but never hidden from keyboards or touch (no hover there).
					className="shrink-0 opacity-0 transition-opacity focus-visible:opacity-100 disabled:opacity-0 group-hover:opacity-100 [@media(hover:none)]:opacity-100"
				>
					<Plus className="size-4" />
				</Button>
			</p>
			<pre className="mt-1 overflow-x-auto whitespace-pre-wrap break-words rounded bg-muted px-2 py-1 font-mono text-[11px] text-foreground/80">
				{entry.syntax}
			</pre>
			<p className="mt-1 text-muted-foreground text-xs">{entry.blurb}</p>
		</li>
	);
}

export default function MarkdownReferencePanel() {
	const [query, setQuery] = useState("");
	const { hasEditor } = useActiveEditor();
	const searchId = useId();

	const groups = useMemo(() => groupByCategory(filterSyntax(query)), [query]);
	const isEmpty = groups.length === 0;

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
				{isEmpty ? (
					<p className="px-3 py-6 text-center text-muted-foreground text-sm">
						No syntax matches “{query}”.
					</p>
				) : (
					groups.map(([category, entries]) => (
						<article key={category}>
							<h3 className="sticky top-0 z-10 border-border border-b bg-card px-3 py-1 font-medium text-[10px] text-muted-foreground uppercase tracking-wide">
								{category}
							</h3>
							<ul>
								{entries.map((entry) => (
									<EntryRow key={entry.id} entry={entry} canInsert={hasEditor} />
								))}
							</ul>
						</article>
					))
				)}
			</ScrollArea>
		</section>
	);
}

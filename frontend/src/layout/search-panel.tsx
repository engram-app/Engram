import { Search, SlidersHorizontal, X } from "lucide-react";
import { type KeyboardEvent, useEffect, useRef, useState } from "react";
import { Link } from "react-router";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { noteName } from "@/lib/note-name";
import { useDebouncedValue } from "@/lib/use-debounced-value";
import { type SearchFilters, type SearchResult, useSearch } from "../api/queries";
import { useActiveVaultSlug } from "../api/vault-slug";
import { useRailView } from "./rail-view-context";
import { pushRecent, readRecent } from "./recent-searches";

const SEARCH_LIMIT = 20;

/** The four date filters, so the fields and their labels stay in one place. */
const DATE_FILTERS: ReadonlyArray<{ key: keyof SearchFilters; label: string }> = [
	{ key: "createdAfter", label: "Created after" },
	{ key: "createdBefore", label: "Created before" },
	{ key: "updatedAfter", label: "Updated after" },
	{ key: "updatedBefore", label: "Updated before" },
];

/**
 * Split `text` on every case-insensitive occurrence of `term`, keeping the
 * separators, so the matched runs can be wrapped in <mark>.
 *
 * The term is escaped before it reaches the RegExp: a query is arbitrary user
 * text, and something as ordinary as "c++" or "a(b" would otherwise throw on
 * every keystroke.
 */
function splitOnMatches(text: string, term: string): string[] {
	const trimmed = term.trim();
	if (!trimmed) {
		return [text];
	}
	const escaped = trimmed.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
	return text.split(new RegExp(`(${escaped})`, "giu"));
}

function Highlighted({ text, term }: { text: string; term: string }) {
	const parts = splitOnMatches(text, term);
	return (
		<>
			{parts.map((part, i) =>
				part.toLowerCase() === term.trim().toLowerCase() ? (
					// biome-ignore lint/suspicious/noArrayIndexKey: split() output is positional — the index IS the identity, and the array is rebuilt whenever text or term changes.
					<mark key={i} className="bg-primary/25 text-foreground">
						{part}
					</mark>
				) : (
					part
				),
			)}
		</>
	);
}

const filterInputClasses =
	"rounded-md border border-border bg-background px-2 py-1 text-xs placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring";

/**
 * `hideHeader` is for the mobile drawer, which supplies its own titled header
 * and a close button — rendering a second one inside the panel stacked two
 * headers on top of each other.
 */
function SearchPanel({
	hideHeader = false,
	onNavigate,
}: {
	hideHeader?: boolean;
	onNavigate?: () => void;
}) {
	const { setView } = useRailView();
	const [input, setInput] = useState("");
	const [filters, setFilters] = useState<SearchFilters>({});
	const [filtersOpen, setFiltersOpen] = useState(false);
	// -1 = nothing selected. Enter must do nothing until an arrow key has been
	// pressed, so that a query typed and submitted does not open a stale row.
	const [activeIndex, setActiveIndex] = useState(-1);
	const activeCount = Object.values(filters).filter(Boolean).length;
	// True debounce, not useDeferredValue: deferral only delays rendering —
	// every settled keystroke still became a new query key, i.e. one vector
	// search (Voyage embed + Qdrant) per character typed.
	const deferred = useDebouncedValue(input.trim(), 300);
	const { data: results, isLoading, error } = useSearch(deferred, filters);
	const [recent, setRecent] = useState<string[]>(() => readRecent());

	function setDateFilter(key: keyof SearchFilters, rawValue: string) {
		setFilters((f) => ({ ...f, [key]: rawValue ? `${rawValue}T00:00:00Z` : undefined }));
	}
	const inputRef = useRef<HTMLInputElement>(null);
	const listRef = useRef<HTMLDivElement>(null);
	const lastRecordedRef = useRef<string>("");
	const hasResults = (results?.length ?? 0) > 0;

	useEffect(() => {
		inputRef.current?.focus();
	}, []);

	useEffect(() => {
		if (deferred.length >= 2 && hasResults && lastRecordedRef.current !== deferred) {
			lastRecordedRef.current = deferred;
			setRecent(pushRecent(deferred));
		}
	}, [deferred, hasResults]);

	const close = () => setView("files");
	const resultCount = results?.length ?? 0;

	/**
	 * Drive the result list from the input, Obsidian-style — without this you
	 * have to leave the field and tab through every row to reach one.
	 *
	 * Enter opens by clicking the selected row's anchor rather than navigating
	 * from a URL built here: the row already knows its href (vault-scoped or
	 * legacy) and its own onNavigate, and going through the DOM keeps one source
	 * for both instead of duplicating the routing rule.
	 */
	function onInputKeyDown(e: KeyboardEvent<HTMLInputElement>) {
		if (e.key === "Escape") {
			close();
			return;
		}
		if (e.key === "ArrowDown" || e.key === "ArrowUp") {
			if (resultCount === 0) {
				return;
			}
			// Arrows would otherwise move the caret inside the input.
			e.preventDefault();
			// Clamped, not wrapped: on a capped list, wrapping from the last row to
			// the first reads as "there is more" when there is not.
			setActiveIndex((i) =>
				e.key === "ArrowDown" ? Math.min(i + 1, resultCount - 1) : Math.max(i - 1, 0),
			);
			return;
		}
		if (e.key === "Enter" && activeIndex >= 0) {
			e.preventDefault();
			listRef.current?.querySelector<HTMLAnchorElement>("[data-active-result]")?.click();
		}
	}

	return (
		<div className="flex h-full flex-col">
			{hideHeader ? null : (
				<header className="flex shrink-0 items-center justify-between border-border border-b px-3 py-2">
					<h2 className="font-semibold text-muted-foreground text-xs uppercase tracking-wide">
						Search
					</h2>
					<Button
						variant="ghost"
						size="icon-sm"
						aria-label="Close search"
						title="Return to files"
						onClick={close}
					>
						<X className="h-4 w-4" />
					</Button>
				</header>
			)}
			<div className="border-border border-b p-2">
				<div className="flex items-center gap-1.5">
					<label className="relative block flex-1">
						<Search className="pointer-events-none absolute top-1/2 left-2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
						<input
							ref={inputRef}
							type="search"
							placeholder="Search your notes…"
							value={input}
							onChange={(e) => {
								setInput(e.target.value);
								// Drop the highlight: on the next query that index points at a
								// row that is no longer on screen, and Enter would open it.
								setActiveIndex(-1);
							}}
							onKeyDown={onInputKeyDown}
							className="w-full rounded-md border border-border bg-background py-1.5 pr-2 pl-7 text-sm placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
						/>
					</label>
					<button
						type="button"
						// Icon-only, so the count has to reach a screen reader through the
						// label — aria-label overrides the badge text for the accessible
						// name, it does not append to it.
						aria-label={activeCount > 0 ? `Filters, ${activeCount} active` : "Filters"}
						aria-expanded={filtersOpen}
						title="Filters"
						onClick={() => setFiltersOpen((open) => !open)}
						className={`relative shrink-0 rounded-md border p-1.5 transition-colors hover:bg-accent ${
							activeCount > 0 || filtersOpen
								? "border-primary/40 bg-primary/10 text-primary"
								: "border-border text-muted-foreground hover:text-foreground"
						}`}
					>
						<SlidersHorizontal className="size-4" />
						{/* The count is what keeps a COLLAPSED panel honest: without it a
						    filter left on silently narrows every later search. */}
						{activeCount > 0 ? (
							<span className="absolute -top-1.5 -right-1.5 flex size-4 items-center justify-center rounded-full bg-primary font-medium text-[10px] text-primary-foreground">
								{activeCount}
							</span>
						) : null}
					</button>
				</div>
				{filtersOpen ? (
					<fieldset className="mt-2 grid grid-cols-2 gap-2">
						<legend className="sr-only">Filter search results</legend>
						<label className="col-span-2 flex flex-col gap-1 text-muted-foreground text-xs">
							Type
							<input
								type="text"
								placeholder="e.g. Playbook"
								value={filters.type ?? ""}
								onChange={(e) => setFilters((f) => ({ ...f, type: e.target.value || undefined }))}
								className={filterInputClasses}
							/>
						</label>
						{DATE_FILTERS.map(({ key, label }) => (
							<label key={key} className="flex flex-col gap-1 text-muted-foreground text-xs">
								{label}
								<input
									type="date"
									// CONTROLLED. Uncontrolled, these kept their text after a
									// reset, so the panel showed a filter it was no longer
									// applying. The state holds an ISO instant; the input wants
									// a bare date, hence the slice.
									value={filters[key]?.slice(0, 10) ?? ""}
									onChange={(e) => setDateFilter(key, e.target.value)}
									className={filterInputClasses}
								/>
							</label>
						))}
						{/* Lives inside the panel now that the trigger is icon-only: the
						    badge says a filter is on, and this is where you come to change
						    one anyway. */}
						{activeCount > 0 ? (
							<button
								type="button"
								onClick={() => setFilters({})}
								className="col-span-2 justify-self-start rounded-md px-1.5 py-1 text-muted-foreground text-xs hover:bg-accent hover:text-foreground"
							>
								Clear filters
							</button>
						) : null}
					</fieldset>
				) : null}
			</div>
			<ScrollArea className="flex-1" ref={listRef}>
				{!deferred && recent.length > 0 && (
					<RecentList recent={recent} onPick={(q) => setInput(q)} />
				)}
				{Boolean(deferred && isLoading) && (
					<p className="px-3 py-2 text-muted-foreground text-xs">Searching…</p>
				)}
				{error ? (
					<p className="px-3 py-2 text-destructive text-xs">Search failed: {error.message}</p>
				) : null}
				{deferred && results && results.length === 0 && !isLoading && (
					<p className="px-3 py-2 text-muted-foreground text-xs">No results for "{deferred}"</p>
				)}
				{results && results.length > 0 && (
					<>
						<p className="px-3 pt-2 text-muted-foreground text-xs" aria-live="polite">
							{results.length} {results.length === 1 ? "result" : "results"}
							{/* The backend caps at 20, so a bare "20" would read as the
							    whole truth rather than a page of it. */}
							{results.length >= SEARCH_LIMIT ? " (first 20)" : ""}
						</p>
						<ul className="space-y-1 p-2">
							{results.map((r, i) => (
								<li key={r.path}>
									<ResultRow
										result={r}
										term={deferred}
										active={i === activeIndex}
										onNavigate={onNavigate}
									/>
								</li>
							))}
						</ul>
					</>
				)}
			</ScrollArea>
		</div>
	);
}

function RecentList({ recent, onPick }: { recent: string[]; onPick: (q: string) => void }) {
	return (
		<section className="p-2">
			<p className="px-1 pb-1 font-semibold text-muted-foreground text-xs uppercase tracking-wide">
				Recent
			</p>
			<ul className="space-y-0.5">
				{recent.map((q) => (
					<li key={q}>
						<button
							type="button"
							onClick={() => onPick(q)}
							className="block w-full truncate rounded px-2 py-1 text-left text-sm hover:bg-accent"
						>
							{q}
						</button>
					</li>
				))}
			</ul>
		</section>
	);
}

function ResultRow({
	result,
	term,
	active = false,
	onNavigate,
}: {
	result: SearchResult;
	term: string;
	active?: boolean;
	onNavigate?: () => void;
}) {
	const slug = useActiveVaultSlug();
	const ref = useRef<HTMLAnchorElement>(null);

	// Keep the keyboard-selected row on screen. block: "nearest" so moving one
	// row does not recentre the whole list under the reader.
	useEffect(() => {
		if (active) {
			ref.current?.scrollIntoView({ block: "nearest" });
		}
	}, [active]);

	// Orphan hits (no id) are unreachable — render nothing.
	if (result.id === null) {
		return null;
	}
	const href = slug ? `/${slug}/${result.id}` : `/note/${result.id}`;
	return (
		<Link
			ref={ref}
			to={href}
			onClick={onNavigate}
			// The row is selected, not focused — focus stays in the input so you can
			// keep typing. data-* is how the panel finds it again to open it.
			data-active-result={active || undefined}
			className={`block rounded-md border p-2 text-sm hover:border-primary/40 hover:bg-accent ${
				active ? "border-primary/50 bg-accent" : "border-border bg-card"
			}`}
		>
			<p className="font-medium">
				<Highlighted text={noteName(result.path)} term={term} />
			</p>
			{/* The API has always returned this and the row never showed it, so two
			    notes with the same filename were indistinguishable. */}
			{result.folder ? <p className="text-muted-foreground text-xs">{result.folder}</p> : null}
			{Boolean(result.heading_path) && (
				<p className="text-muted-foreground text-xs">↳ {result.heading_path}</p>
			)}
			{Boolean(result.snippet) && (
				<p className="mt-1 line-clamp-2 text-muted-foreground text-xs">
					<Highlighted text={result.snippet} term={term} />
				</p>
			)}
		</Link>
	);
}

export default SearchPanel;

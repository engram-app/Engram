import { Search, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { Link } from "react-router";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useDebouncedValue } from "@/lib/use-debounced-value";
import { type SearchFilters, type SearchResult, useSearch } from "../api/queries";
import { useRailView } from "./rail-view-context";
import { pushRecent, readRecent } from "./recent-searches";

const filterInputClasses =
	"rounded-md border border-border bg-background px-2 py-1 text-xs placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring";

function SearchPanel() {
	const { setView } = useRailView();
	const [input, setInput] = useState("");
	const [filters, setFilters] = useState<SearchFilters>({});
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

	return (
		<div className="flex h-full flex-col">
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
			<div className="border-border border-b p-2">
				<label className="relative block">
					<Search className="pointer-events-none absolute top-1/2 left-2 h-3.5 w-3.5 -translate-y-1/2 text-muted-foreground" />
					<input
						ref={inputRef}
						type="search"
						placeholder="Search your notes…"
						value={input}
						onChange={(e) => setInput(e.target.value)}
						onKeyDown={(e) => {
							if (e.key === "Escape") {
								close();
							}
						}}
						className="w-full rounded-md border border-border bg-background py-1.5 pr-2 pl-7 text-sm placeholder:text-muted-foreground focus:outline-none focus:ring-2 focus:ring-ring"
					/>
				</label>
				<fieldset className="mt-2 flex flex-wrap items-center gap-1.5">
					<legend className="sr-only">Filter search results</legend>
					<input
						type="text"
						placeholder="Type (e.g. Playbook)"
						aria-label="filter by type"
						value={filters.type ?? ""}
						onChange={(e) => setFilters((f) => ({ ...f, type: e.target.value || undefined }))}
						className={filterInputClasses}
					/>
					<input
						type="date"
						aria-label="created after"
						onChange={(e) => setDateFilter("createdAfter", e.target.value)}
						className={filterInputClasses}
					/>
					<input
						type="date"
						aria-label="created before"
						onChange={(e) => setDateFilter("createdBefore", e.target.value)}
						className={filterInputClasses}
					/>
					<input
						type="date"
						aria-label="updated after"
						onChange={(e) => setDateFilter("updatedAfter", e.target.value)}
						className={filterInputClasses}
					/>
					<input
						type="date"
						aria-label="updated before"
						onChange={(e) => setDateFilter("updatedBefore", e.target.value)}
						className={filterInputClasses}
					/>
				</fieldset>
			</div>
			<ScrollArea className="flex-1">
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
					<ul className="space-y-1 p-2">
						{results.map((r) => (
							<li key={r.path}>
								<ResultRow result={r} />
							</li>
						))}
					</ul>
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

function ResultRow({ result }: { result: SearchResult }) {
	// Orphan hits (no id) are unreachable — render nothing.
	if (result.id === null) {
		return null;
	}
	const href = `/note/${result.id}`;
	return (
		<Link
			to={href}
			className="block rounded-md border border-border bg-card p-2 text-sm hover:border-primary/40 hover:bg-accent"
		>
			<p className="font-medium">{result.title || lastSegment(result.path)}</p>
			{result.heading_path && result.heading_path !== result.title && (
				<p className="text-muted-foreground text-xs">↳ {result.heading_path}</p>
			)}
			{Boolean(result.snippet) && (
				<p className="mt-1 line-clamp-2 text-muted-foreground text-xs">{result.snippet}</p>
			)}
		</Link>
	);
}

function lastSegment(path: string): string {
	return (path.split("/").pop() ?? path).replace(/\.md$/u, "");
}

export default SearchPanel;

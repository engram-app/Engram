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

type DatePreset = "any" | "7d" | "30d" | "year" | "custom";
type DateField = "updated" | "created";

const DATE_PRESETS: ReadonlyArray<{ id: DatePreset; label: string }> = [
	{ id: "any", label: "Any time" },
	{ id: "7d", label: "7 days" },
	{ id: "30d", label: "30 days" },
	{ id: "year", label: "This year" },
	{ id: "custom", label: "Custom…" },
];

const DATE_FIELDS: ReadonlyArray<{ id: DateField; label: string }> = [
	{ id: "updated", label: "Updated" },
	{ id: "created", label: "Created" },
];

/**
 * Midnight UTC `days` ago.
 *
 * Quantised to the START OF THE DAY on purpose. An instant-accurate "7 days
 * ago" would differ by milliseconds on every render, and since the filters end
 * up in the react-query key, that is a new key — and a new vector search —
 * every single time the panel renders.
 */
function daysAgoUtc(days: number): string {
	const d = new Date();
	d.setUTCDate(d.getUTCDate() - days);
	d.setUTCHours(0, 0, 0, 0);
	return d.toISOString();
}

function startOfYearUtc(): string {
	return new Date(Date.UTC(new Date().getUTCFullYear(), 0, 1)).toISOString();
}

/** A bare `yyyy-mm-dd` from a date input, as the instant the API expects. */
function dayStart(value: string): string | undefined {
	return value ? `${value}T00:00:00Z` : undefined;
}

/**
 * Fold the date controls into the flat payload the API takes.
 *
 * The UI deliberately does NOT mirror that payload: it used to, and the result
 * was a cross-product of {created, updated} x {after, before} — four identical
 * date boxes. One preset row plus an escape hatch covers the same ground.
 */
function dateFilters(
	preset: DatePreset,
	field: DateField,
	from: string,
	to: string,
): SearchFilters {
	const bounds =
		preset === "custom"
			? { after: dayStart(from), before: dayStart(to) }
			: preset === "year"
				? { after: startOfYearUtc() }
				: preset === "7d" || preset === "30d"
					? { after: daysAgoUtc(preset === "7d" ? 7 : 30) }
					: {};
	return {
		...(bounds.after ? { [`${field}After`]: bounds.after } : {}),
		...(bounds.before ? { [`${field}Before`]: bounds.before } : {}),
	};
}

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

/** Chip chrome for the visually-hidden radios above. */
const chipClasses =
	"inline-block rounded-full border border-border px-2.5 py-1 text-xs text-muted-foreground transition-colors peer-checked:border-primary/40 peer-checked:bg-primary/15 peer-checked:text-primary peer-focus-visible:ring-2 peer-focus-visible:ring-ring hover:bg-accent";

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
	const [type, setType] = useState("");
	const [preset, setPreset] = useState<DatePreset>("any");
	const [dateField, setDateField] = useState<DateField>("updated");
	const [customFrom, setCustomFrom] = useState("");
	const [customTo, setCustomTo] = useState("");
	const [filtersOpen, setFiltersOpen] = useState(false);
	// -1 = nothing selected. Enter must do nothing until an arrow key has been
	// pressed, so that a query typed and submitted does not open a stale row.
	const [activeIndex, setActiveIndex] = useState(-1);
	const filters: SearchFilters = {
		...(type ? { type } : {}),
		...dateFilters(preset, dateField, customFrom, customTo),
	};
	// Counted as the user sees them — a custom range is ONE filter even though
	// it becomes two keys in the payload, and "Custom" with no dates yet
	// constrains nothing so it must not read as on.
	const dateActive = preset === "custom" ? Boolean(customFrom || customTo) : preset !== "any";
	const activeCount = (type ? 1 : 0) + (dateActive ? 1 : 0);

	function clearFilters() {
		setType("");
		setPreset("any");
		setDateField("updated");
		setCustomFrom("");
		setCustomTo("");
	}
	// True debounce, not useDeferredValue: deferral only delays rendering —
	// every settled keystroke still became a new query key, i.e. one vector
	// search (Voyage embed + Qdrant) per character typed.
	const deferred = useDebouncedValue(input.trim(), 300);
	const { data: results, isLoading, error } = useSearch(deferred, filters);
	const [recent, setRecent] = useState<string[]>(() => readRecent());

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
					<div className="mt-2 space-y-3">
						<label className="flex flex-col gap-1 text-muted-foreground text-xs">
							Type
							<input
								type="text"
								placeholder="e.g. Playbook"
								value={type}
								onChange={(e) => setType(e.target.value)}
								className={filterInputClasses}
							/>
						</label>
						{/* Real radios, visually hidden and styled through peer-checked.
						    A single-select chip row IS a radiogroup, and doing it natively
						    buys arrow-key navigation and the right semantics for nothing —
						    buttons with aria-pressed would need a roving tabindex to match. */}
						<fieldset>
							<legend className="pb-1 text-muted-foreground text-xs">Modified</legend>
							<div className="flex flex-wrap gap-1">
								{DATE_PRESETS.map(({ id, label }) => (
									<label key={id} className="cursor-pointer">
										<input
											type="radio"
											name="engram-date-preset"
											className="peer sr-only"
											checked={preset === id}
											onChange={() => setPreset(id)}
										/>
										<span className={chipClasses}>{label}</span>
									</label>
								))}
							</div>
						</fieldset>
						{preset === "custom" ? (
							<div className="space-y-2">
								<fieldset>
									<legend className="pb-1 text-muted-foreground text-xs">Applies to</legend>
									<div className="flex gap-1">
										{DATE_FIELDS.map(({ id, label }) => (
											<label key={id} className="cursor-pointer">
												<input
													type="radio"
													name="engram-date-field"
													className="peer sr-only"
													checked={dateField === id}
													onChange={() => setDateField(id)}
												/>
												<span className={chipClasses}>{label}</span>
											</label>
										))}
									</div>
								</fieldset>
								<div className="grid grid-cols-2 gap-2">
									<label className="flex flex-col gap-1 text-muted-foreground text-xs">
										From
										<input
											type="date"
											// CONTROLLED. Uncontrolled, these kept their text after a
											// reset and showed a filter that was no longer applied.
											value={customFrom}
											onChange={(e) => setCustomFrom(e.target.value)}
											className={filterInputClasses}
										/>
									</label>
									<label className="flex flex-col gap-1 text-muted-foreground text-xs">
										To
										<input
											type="date"
											value={customTo}
											onChange={(e) => setCustomTo(e.target.value)}
											className={filterInputClasses}
										/>
									</label>
								</div>
							</div>
						) : null}
						{/* Lives inside the panel now that the trigger is icon-only: the
						    badge says a filter is on, and this is where you come to change
						    one anyway. */}
						{activeCount > 0 ? (
							<button
								type="button"
								onClick={clearFilters}
								className="rounded-md px-1.5 py-1 text-muted-foreground text-xs hover:bg-accent hover:text-foreground"
							>
								Clear filters
							</button>
						) : null}
					</div>
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

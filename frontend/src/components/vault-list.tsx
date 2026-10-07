import { Search } from "lucide-react";
import type React from "react";
import { useState } from "react";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useAutofocus } from "@/hooks/use-autofocus";

// Above this many vaults the list gets a search box. Below it, the box is
// pure clutter - every vault is already on screen.
const SEARCH_THRESHOLD = 8;

type VaultSearch = ReturnType<typeof useVaultSearch>;

// Focus follows the click that opened the field, so it focuses on mount. That
// holds only because this mounts when `searching` flips to true; render it
// already open on load and it would steal focus.
function SearchInput({ search, status }: { search: VaultSearch; status?: string }) {
	const ref = useAutofocus<HTMLInputElement>();
	return (
		<>
			<input
				ref={ref}
				type="search"
				value={search.filter}
				onChange={(e) => search.setFilter(e.target.value)}
				onBlur={() => search.filter === "" && search.setSearching(false)}
				placeholder="Search vaults"
				aria-label="Search vaults"
				className="rounded-lg border border-border bg-background p-2 text-sm"
			/>
			{status ? (
				<p aria-live="polite" className="text-muted-foreground text-xs">
					{status}
				</p>
			) : null}
		</>
	);
}

export function countLabel(notes?: number, files?: number): string {
	const parts = [`${(notes ?? 0).toLocaleString()} notes`];
	if (files) {
		parts.push(`${files.toLocaleString()} files`);
	}
	return parts.join(" · ");
}

// The scrollbar lives in a gutter that `-me-3` pulls out of the column and
// `pe-3` hands back to the rows, so a scrolling list is exactly as wide as the
// controls around it. `always` keeps the bar visible: a hover-only bar on a
// list that fits whole rows gives no hint there is more below. 18rem shows four
// and a half rows for the same reason, so the fifth is visibly cut off.
export function VaultRows({ scroll, children }: { scroll: boolean; children: React.ReactNode }) {
	// Unscrolled, the rows are direct children of the caller's flex column, so
	// they need no wrapper of their own.
	return scroll ? (
		<ScrollArea type="always" className="-me-3 h-[18rem]">
			<div className="flex flex-col gap-2 pe-3">{children}</div>
		</ScrollArea>
	) : (
		children
	);
}

// A picker with four vaults does not need a search box; one with forty is
// unusable without it. Only the second case pays for the extra control.
export function useVaultSearch<T extends { name: string }>(vaults: T[]) {
	const [filter, setFilter] = useState("");
	const [searching, setSearching] = useState(false);
	const showFilter = vaults.length > SEARCH_THRESHOLD;
	const needle = filter.trim().toLowerCase();
	const shown =
		showFilter && needle ? vaults.filter((v) => v.name.toLowerCase().includes(needle)) : vaults;
	return { filter, setFilter, searching, setSearching, showFilter, needle, shown };
}

export function VaultSearchToggle({ search }: { search: VaultSearch }) {
	if (!search.showFilter || search.searching) {
		return null;
	}
	return (
		<button
			type="button"
			onClick={() => search.setSearching(true)}
			aria-label="Search vaults"
			className="rounded p-1 text-muted-foreground hover:text-foreground"
		>
			<Search className="size-4" />
		</button>
	);
}

// `status` is announced politely: filtering hides rows without changing the
// selection, so it is the only way to see what is still chosen off-screen.
export function VaultSearchField({ search, status }: { search: VaultSearch; status?: string }) {
	return search.searching ? <SearchInput search={search} status={status} /> : null;
}

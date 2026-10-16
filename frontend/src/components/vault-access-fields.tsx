import { Search, X } from "lucide-react";
import { useId, useState } from "react";
import { type AccessLevel, type AccessRequest, capLevel } from "@/components/access-level-select";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useVaultSearch, VaultSummary } from "@/components/vault-list";
import { useT } from "@/i18n/locale-provider";
import type { UIText } from "@/i18n/ui-text";
import { cn } from "@/lib/utils";

interface AccessVault {
	id: string;
	name: string;
	is_default?: boolean;
	note_count?: number;
	attachment_count?: number;
}

type Column = "read" | "write";

type VaultSearch = ReturnType<typeof useVaultSearch>;

// A plain search field over the list, shown once the list is long enough to
// need it. Escape or Clear empties it; the selection never changes.
function VaultSearchInput({ search }: { search: VaultSearch }) {
	const { t } = useT();
	return (
		<span className="relative mb-1.5 flex shrink-0 items-center">
			<Search
				aria-hidden
				className="pointer-events-none absolute start-2.5 size-4 text-muted-foreground"
			/>
			<Input
				type="search"
				value={search.filter}
				onChange={(e) => search.setFilter(e.target.value)}
				onKeyDown={(e) => {
					// Inside the key form Enter would submit it; typing already filtered.
					if (e.key === "Enter") {
						e.preventDefault();
					} else if (e.key === "Escape" && search.filter) {
						e.preventDefault();
						e.stopPropagation();
						search.setFilter("");
					}
				}}
				placeholder={t("Search vaults")}
				aria-label={t("Search vaults")}
				className="px-8 [&::-webkit-search-cancel-button]:hidden"
			/>
			{search.filter ? (
				<Button
					type="button"
					variant="ghost"
					size="icon-xs"
					onClick={() => search.setFilter("")}
					aria-label={t("Clear")}
					className="absolute end-1"
				>
					<X />
				</Button>
			) : null}
		</span>
	);
}

// What one box does to a level. Write implies Read, so checking Write checks
// Read and unchecking Read unchecks Write. Without levels the single box is
// in (write) or out.
function toggled(level: AccessLevel, column: Column, on: boolean, leveled: boolean): AccessLevel {
	if (!leveled) {
		return on ? "write" : "none";
	}
	if (column === "write") {
		return on ? "write" : "read";
	}
	if (on) {
		return level === "none" ? "read" : level;
	}
	return "none";
}

function isOn(level: AccessLevel, column: Column): boolean {
	return column === "write" ? level === "write" : level !== "none";
}

export interface VaultAccessState {
	perVault: boolean;
	allLevel: AccessLevel;
	levels: Record<string, AccessLevel>;
	later: AccessLevel;
}

// The picker state for access a credential already has: one level on every
// vault and on later vaults is All vaults, anything else is Choose vaults.
// A vault missing from `levels` (created since) keeps the later level, which
// is what the backend grants it.
export function accessStateOf(
	levels: { vault_id: string; level: AccessLevel }[],
	later: AccessLevel,
): VaultAccessState {
	const all = later !== "none" && levels.every((l) => l.level === later);
	return {
		perVault: !all,
		allLevel: all ? later : "write",
		levels: all ? {} : Object.fromEntries(levels.map((l) => [l.vault_id, l.level])),
		later,
	};
}

// One level on every vault (including ones created later), or a level per
// vault plus a policy for vaults created later (#174, #332). One state for
// OAuth consent, the New API Key dialog and Edit access; `initial` pre-fills it.
export function useVaultAccess(initial?: VaultAccessState) {
	const [perVault, setPerVault] = useState(initial?.perVault ?? false);
	// "All vaults" starts at Read and write, the pre-levels grant.
	const [allLevel, setAllLevel] = useState<AccessLevel>(initial?.allLevel ?? "write");
	const [levels, setLevels] = useState<Record<string, AccessLevel>>(initial?.levels ?? {});
	// Picking vaults never grants future ones unless the user says so.
	const [later, setLater] = useState<AccessLevel>(initial?.later ?? "none");
	// The vaults on screen when Choose vaults was picked. One that appears
	// after (a refetch) was never shown, so it gets the later policy.
	const [known, setKnown] = useState<ReadonlySet<string>>(new Set());
	// Choosing vaults starts from nothing checked: the user picks each vault.
	const start = (id: string): AccessLevel => (known.has(id) ? "none" : later);
	const levelOf = (id: string): AccessLevel => levels[id] ?? start(id);
	return {
		perVault,
		setPerVault: (on: boolean, ids: string[]) => {
			if (on) {
				setKnown(new Set(ids));
			}
			setPerVault(on);
		},
		allLevel,
		setAllLevel,
		later,
		setLater,
		levelOf,
		// Whether the selection reaches any vault, now or later, given the vaults
		// it can see. The backend refuses one that reaches none. The one test
		// for both consent and the key dialog.
		reaches: (ids: string[]) =>
			perVault ? later !== "none" || ids.some((id) => levelOf(id) !== "none") : allLevel !== "none",
		// Whether the selection writes anywhere, given the vaults it can see.
		writes: (ids: string[]) =>
			perVault
				? later === "write" || ids.some((id) => levelOf(id) === "write")
				: allLevel === "write",
		// The request body for the vaults it can see: All vaults is the policy
		// alone; Choose vaults lists each vault, spelling out "none" only where
		// the policy would otherwise reach it. `max` caps write (read only).
		request: (
			ids: string[],
			max: "read" | "write" = "write",
		): Required<Pick<AccessRequest, "default_access">> & AccessRequest => {
			if (!perVault) {
				return { default_access: capLevel(allLevel, max) };
			}
			const policy = capLevel(later, max);
			return {
				vault_access: Object.fromEntries(
					ids
						.map((id): [string, AccessLevel] => [id, capLevel(levelOf(id), max)])
						.filter(([, level]) => policy !== "none" || level !== "none"),
				),
				default_access: policy,
			};
		},
		setLevels: (ids: string[], next: (level: AccessLevel) => AccessLevel) =>
			setLevels((prev) => ({
				...prev,
				...Object.fromEntries(ids.map((id) => [id, next(prev[id] ?? start(id))])),
			})),
	};
}

export type VaultAccess = ReturnType<typeof useVaultAccess>;

// Scope (All vaults / Choose vaults), then rows that each carry their own
// labelled boxes: one row for every vault, or a row per vault under a header
// (Vault + search, select-all) and the pinned policy for vaults created later.
// Without levels (an Obsidian device, or a backend that predates them) there is
// no later-vaults policy and one box per row. `lockReadOnly` drops Write (an
// `mcp:read` client).
//
// Fits its container by construction: rendered as items of a flex column, the
// vault list is the only part that shrinks, then scrolls.
export function VaultAccessFields({
	access,
	vaults,
	legend,
	leveled = true,
	lockReadOnly = false,
}: {
	access: VaultAccess;
	vaults: AccessVault[];
	legend: UIText;
	leveled?: boolean;
	lockReadOnly?: boolean;
}) {
	const { t } = useT();
	const id = useId();
	const search = useVaultSearch(vaults);
	const columns: { key: Column; label: UIText }[] = leveled
		? lockReadOnly
			? [{ key: "read", label: t("Read") }]
			: [
					{ key: "read", label: t("Read") },
					{ key: "write", label: t("Write") },
				]
		: [{ key: "read", label: t("Read and write") }];
	const allIds = vaults.map((v) => v.id);
	// Select-all never changes a row the user cannot see: under a filter it
	// acts on the shown rows, otherwise on every vault.
	const targets = search.needle ? search.shown : vaults;
	const targetIds = targets.map((v) => v.id);
	// Select-all also sets the later-vaults row (always shown), so it counts
	// toward the tri-state: [boxes on, boxes in scope].
	const selectAll = (key: Column): [number, number] => {
		const on = targets.filter((v) => isOn(access.levelOf(v.id), key)).length;
		return leveled
			? [on + (isOn(access.later, key) ? 1 : 0), targets.length + 1]
			: [on, targets.length];
	};
	const reached = vaults.filter((v) => access.levelOf(v.id) !== "none").length;

	// The same visible words in every row (and the header) keep the boxes
	// lined up. The name says which row, so a screen reader hears the vault.
	const boxes = (
		name: (column: UIText) => UIText,
		isChecked: (column: Column) => boolean,
		onChange: (column: Column, on: boolean) => void,
		mixed?: (column: Column) => boolean,
	) => (
		<span className="ms-auto flex shrink-0 items-center gap-3">
			{columns.map(({ key, label }) => (
				<label key={key} className="flex cursor-pointer items-center gap-1.5 font-normal text-sm">
					{label}
					<input
						type="checkbox"
						aria-label={name(label)}
						checked={isChecked(key)}
						ref={
							mixed
								? (el) => {
										if (el) {
											el.indeterminate = mixed(key);
										}
									}
								: undefined
						}
						onChange={(e) => onChange(key, e.target.checked)}
						className="size-4 accent-primary"
					/>
				</label>
			))}
		</span>
	);
	// Narrow screens (German at 390px) wrap the boxes under the name. Every
	// row (header, policy, vaults, All vaults) keeps the same end gutter, the
	// width of the overlay scrollbar, so the bar never covers a box and the
	// columns line up whether it shows or not.
	const row = "flex flex-wrap items-center gap-x-3 gap-y-1 py-2.5 pe-5";
	const named = "min-w-0 flex-1 basis-28";

	return (
		<>
			<fieldset className="grid grid-cols-2 gap-1 rounded-lg border border-border bg-muted p-1 text-sm">
				<legend className="sr-only">{legend}</legend>
				{(
					[
						[false, t("All vaults")],
						[true, t("Choose vaults")],
					] as const
				).map(([perVault, text]) => (
					<label
						key={String(perVault)}
						className={cn(
							"flex cursor-pointer items-center justify-center rounded-md px-3 py-1.5 text-center font-medium transition focus-within:ring-2 focus-within:ring-ring",
							access.perVault === perVault
								? "bg-background text-foreground shadow-sm"
								: "text-muted-foreground hover:text-foreground",
						)}
					>
						<input
							type="radio"
							name={id}
							checked={access.perVault === perVault}
							onChange={() => access.setPerVault(perVault, allIds)}
							className="sr-only"
						/>
						{text}
					</label>
				))}
			</fieldset>

			{access.perVault ? (
				<div className={cn("flex min-h-0 flex-1 flex-col", vaults.length > 3 && "min-h-[17rem]")}>
					{search.showFilter ? <VaultSearchInput search={search} /> : null}
					<div className={cn(row, "shrink-0 py-2")}>
						<span data-slot="vault-header" className={cn(named, "font-semibold text-base")}>
							{search.needle ? t("Matching vaults") : t("All vaults")}
						</span>
						{boxes(
							(column) =>
								search.needle
									? t("{column}: shown vaults", { column })
									: t("{column}: all vaults", { column }),
							(key) => {
								const [on, total] = selectAll(key);
								return on > 0 && on === total;
							},
							(key, on) => {
								access.setLevels(targetIds, (level) => toggled(level, key, on, leveled));
								if (leveled) {
									access.setLater(toggled(access.later, key, on, true));
								}
							},
							(key) => {
								const [on, total] = selectAll(key);
								return on > 0 && on < total;
							},
						)}
					</div>
					{leveled ? (
						// A policy, not a vault: pinned first, set apart by a tint and a stronger divider.
						<ul className="shrink-0 border-border border-t border-b-2">
							<li className={cn(row, "bg-muted/40")}>
								<span className={cn(named, "flex flex-col gap-0.5")}>
									<span className="font-medium text-foreground text-sm">
										{t("Vaults you create later")}
									</span>
									{/* True only at none: an edited credential can start at read or write. */}
									{access.later === "none" ? (
										<span className="text-muted-foreground text-xs">
											{t("No access unless you change this here.")}
										</span>
									) : null}
								</span>
								{boxes(
									(column) =>
										t("{column}: {vault}", { column, vault: t("Vaults you create later") }),
									(key) => isOn(access.later, key),
									(key, on) => access.setLater(toggled(access.later, key, on, true)),
								)}
							</li>
						</ul>
					) : null}
					{/* The only part that shrinks. The wrapper keeps about three rows
					    (17rem with the header and policy), then the card itself scrolls. The overlay scrollbar takes no width,
					    so the boxes stay lined up with the rows above. The viewport is a
					    flex child, not `height: 100%`: in a dialog capped only by
					    max-height the root's height is not definite, so a percentage
					    resolves to the content and the list spills past the footer. */}
					<ScrollArea
						viewportLabel={t("Vaults")}
						className="flex min-h-0 flex-1 flex-col"
						viewportClassName="min-h-0 flex-1"
					>
						<ul className={cn("divide-y divide-border", !leveled && "border-border border-t")}>
							{search.shown.map((v) => {
								const level = access.levelOf(v.id);
								return (
									<li key={v.id} className={row}>
										<span className={named}>
											<VaultSummary vault={v} />
										</span>
										{boxes(
											(column) => t("{column}: {vault}", { column, vault: v.name }),
											(key) => isOn(level, key),
											(key, on) =>
												access.setLevels([v.id], (prev) => toggled(prev, key, on, leveled)),
										)}
									</li>
								);
							})}
						</ul>
						{search.needle && search.shown.length === 0 ? (
							<p className="py-3 text-muted-foreground text-sm">
								{t("No vaults match \u0022{filter}\u0022.", { filter: search.filter })}
							</p>
						) : null}
					</ScrollArea>
					{search.needle ? (
						<p aria-live="polite" className="shrink-0 pt-2 text-muted-foreground text-xs">
							{t("{count} of {total} selected", { count: reached, total: vaults.length })}
						</p>
					) : null}
				</div>
			) : (
				<ul className="border-border border-y">
					<li className={row}>
						<span className={cn(named, "font-medium text-foreground text-sm")}>
							{t("All vaults, including ones you create later")}
						</span>
						{boxes(
							(column) =>
								t("{column}: {vault}", {
									column,
									vault: t("All vaults, including ones you create later"),
								}),
							(key) => isOn(access.allLevel, key),
							(key, on) => access.setAllLevel(toggled(access.allLevel, key, on, leveled)),
						)}
					</li>
				</ul>
			)}
		</>
	);
}

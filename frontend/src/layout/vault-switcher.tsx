import { useQueryClient } from "@tanstack/react-query";
import { Check, ChevronDown, Plus } from "lucide-react";
import { type KeyboardEvent, useId, useRef, useState } from "react";
import { useNavigate } from "react-router";
import { SearchField } from "@/components/search-field";
import {
	Dialog,
	DialogContent,
	DialogDescription,
	DialogHeader,
	DialogTitle,
} from "@/components/ui/dialog";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { ScrollArea } from "@/components/ui/scroll-area";
import { VaultCreateForm } from "@/components/vault-create-form";
import { useT } from "@/i18n/locale-provider";
import {
	LIST_ROW_GAP,
	LIST_ROW_HEIGHT,
	listContainer,
	listEmpty,
	listRowClass,
} from "@/lib/ui-classes";
import { cn } from "@/lib/utils";
import { useActiveVaultId } from "../api/active-vault";
import { useVaults } from "../api/queries";
import { vaultPath } from "../routes";

function VaultSwitcher() {
	const { t } = useT();
	const { data: vaults, isLoading } = useVaults();
	const activeId = useActiveVaultId();
	const qc = useQueryClient();
	const navigate = useNavigate();
	const [open, setOpen] = useState(false);
	const [createOpen, setCreateOpen] = useState(false);
	const [query, setQuery] = useState("");
	// The option the keyboard is on. null = "the first match", which is also what
	// a fresh filter should land on.
	const [highlightId, setHighlightId] = useState<string | null>(null);
	const listId = useId();
	const searchRef = useRef<HTMLInputElement>(null);

	if (isLoading) {
		return <p className="px-3 py-2 text-muted-foreground text-xs">{t("Loading vaults…")}</p>;
	}
	if (!vaults || vaults.length === 0) {
		return <p className="px-3 py-2 text-muted-foreground text-xs">{t("No vaults yet")}</p>;
	}

	const active = vaults.find((v) => v.id === activeId) ?? vaults[0]!;
	const needle = query.trim().toLowerCase();
	const matches = needle
		? vaults.filter(
				(v) => v.name.toLowerCase().includes(needle) || v.slug.toLowerCase().includes(needle),
			)
		: vaults;
	const highlighted = matches.find((v) => v.id === highlightId) ?? matches[0];
	const optionId = (id: string) => `${listId}-${id}`;

	// Navigate; VaultRoute writes the active-vault store. Land on the vault
	// root, not the current note, whose id does not exist in the new vault.
	function openVault(slug: string) {
		navigate(vaultPath(slug));
		qc.invalidateQueries();
	}

	function pick(id: string) {
		setOpen(false);
		const target = vaults?.find((v) => v.id === id);
		if (target && target.id !== active.id) {
			openVault(target.slug);
		}
	}

	function onOpenChange(next: boolean) {
		setOpen(next);
		if (next) {
			// Every open starts unfiltered, on the vault you are in.
			setQuery("");
			setHighlightId(active.id);
		}
	}

	function onSearchKeyDown(e: KeyboardEvent<HTMLInputElement>) {
		if (e.key === "Enter") {
			e.preventDefault();
			if (highlighted) {
				pick(highlighted.id);
			}
			return;
		}
		const at = highlighted ? matches.indexOf(highlighted) : -1;
		const moves: Record<string, number> = {
			ArrowDown: Math.min(at + 1, matches.length - 1),
			ArrowUp: Math.max(at - 1, 0),
			Home: 0,
			End: matches.length - 1,
		};
		const to = moves[e.key];
		if (to !== undefined && matches.length > 0) {
			e.preventDefault();
			setHighlightId(matches[to]?.id ?? null);
		}
	}

	return (
		<section className="border-border border-t">
			<Popover open={open} onOpenChange={onOpenChange}>
				<PopoverTrigger className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left outline-none hover:bg-muted aria-expanded:bg-muted">
					<span className="min-w-0 flex-1">
						<span className="block font-medium text-[10px] text-muted-foreground uppercase tracking-wide">
							{t("Vault")}
						</span>
						<span className="block truncate font-medium text-foreground text-sm">
							{active.name}
						</span>
					</span>
					<ChevronDown className="size-4 shrink-0 text-muted-foreground transition-transform group-aria-expanded/dropdown-trigger:rotate-180" />
				</PopoverTrigger>
				<PopoverContent
					side="top"
					align="start"
					arrow={false}
					aria-label={t("Switch vault")}
					// Flush against the trigger (no gap) and square, so the panel and the vault
					// button read as one object; the trigger's own border-t is the seam, so the
					// panel drops its bottom border rather than doubling it.
					sideOffset={0}
					className="w-[var(--radix-popover-trigger-width)] min-w-64 overflow-hidden rounded-none border-b-0 p-0"
					// Land in the search box, not on whichever element Radix finds first.
					onOpenAutoFocus={(e) => {
						e.preventDefault();
						searchRef.current?.focus();
					}}
				>
					{/* The list scrolls; the footer below does not. max-h on the viewport lets
					    a short list stay short and a long one scroll. The scrollbar is an overlay that
					    only shows while scrolling, so it never sits on top of the row highlight. */}
					<ScrollArea type="scroll" viewportClassName="max-h-[min(20rem,50vh)]">
						<div
							id={listId}
							role="listbox"
							aria-label={t("Vaults")}
							className={cn("flex flex-col", listContainer)}
							style={{ gap: LIST_ROW_GAP }}
						>
							{matches.map((v) => (
								// Row look is shared with the file tree (lib/ui-classes). The current vault is the
								// selected chip; hover and the keyboard highlight both own `accent`.
								<div
									key={v.id}
									id={optionId(v.id)}
									role="option"
									tabIndex={-1}
									aria-selected={v.id === active.id}
									data-highlighted={v.id === highlighted?.id || undefined}
									style={{ height: LIST_ROW_HEIGHT }}
									className={cn(
										listRowClass({ selected: v.id === active.id }),
										"cursor-default justify-between pl-2 outline-none",
									)}
									onClick={() => pick(v.id)}
									onKeyDown={(e) => {
										if (e.key === "Enter") {
											pick(v.id);
										}
									}}
									onMouseMove={() => setHighlightId(v.id)}
									ref={(el) => {
										if (v.id === highlighted?.id) {
											el?.scrollIntoView?.({ block: "nearest" });
										}
									}}
								>
									<span className="truncate">{v.name}</span>
									{v.id === active.id ? <Check className="size-4 shrink-0 text-primary" /> : null}
								</div>
							))}
							{matches.length === 0 ? <p className={listEmpty}>{t("No vaults match")}</p> : null}
						</div>
					</ScrollArea>
					<div className={cn("border-border border-t", listContainer)}>
						<button
							type="button"
							style={{ height: LIST_ROW_HEIGHT }}
							className={cn(listRowClass(), "pl-2 outline-none focus-visible:bg-accent")}
							onClick={() => {
								setOpen(false);
								setCreateOpen(true);
							}}
						>
							<Plus className="size-4" />
							{t("New vault")}
						</button>
					</div>
					<div className="border-border border-t p-2">
						<SearchField
							ref={searchRef}
							role="combobox"
							aria-label={t("Search vaults")}
							aria-expanded
							aria-controls={listId}
							aria-activedescendant={highlighted ? optionId(highlighted.id) : undefined}
							placeholder={t("Search vaults…")}
							autoComplete="off"
							spellCheck={false}
							value={query}
							onChange={(e) => {
								setQuery(e.target.value);
								setHighlightId(null);
							}}
							onKeyDown={onSearchKeyDown}
						/>
					</div>
				</PopoverContent>
			</Popover>

			<Dialog open={createOpen} onOpenChange={setCreateOpen}>
				<DialogContent className="sm:max-w-md">
					<DialogHeader>
						<DialogTitle>{t("New vault")}</DialogTitle>
						<DialogDescription>
							{t("A vault holds its own notes and folders, separate from your other vaults.")}
						</DialogDescription>
					</DialogHeader>
					<VaultCreateForm
						autoFocus
						showCancel
						submitLabel={t("Create vault")}
						onCancel={() => setCreateOpen(false)}
						onCreated={(vault) => {
							setCreateOpen(false);
							openVault(vault.slug);
						}}
					/>
				</DialogContent>
			</Dialog>
		</section>
	);
}

export default VaultSwitcher;

import { ListChecks, type LucideIcon } from "lucide-react";
import { Fragment, type ReactNode, useEffect, useRef, useState } from "react";
import { Sheet, SheetContent, SheetDescription, SheetTitle } from "@/components/ui/sheet";
import { useT } from "@/i18n/locale-provider";
import type { UIText } from "@/i18n/ui-text";
import { ACTION_ICONS, type Action, type ActionId, startsGroup } from "./action-list";

interface Props {
	title: string;
	actions: readonly Action[];
	onPick: (id: ActionId) => void;
	onClose: () => void;
	onSelectMore?: () => void;
	/** Its own group, just above the destructive action, which stays last. */
	extra?: ExtraItem;
}

const ROW = "flex w-full items-center gap-3 px-4 py-3 text-left text-base";

/** A row that is not a tree/note action, e.g. the mobile note menu's "Open tools". */
export interface ExtraItem {
	label: UIText;
	icon: LucideIcon;
	onSelect: () => void;
}

/** How long the sheet takes to slide out (Sheet's `duration-200`). */
export const CLOSE_MS = 200;

/**
 * The touch menu: a bottom sheet. Built on Sheet, so it stacks above another
 * open dialog (the files drawer it is opened from) and gets Escape, focus
 * trapping and the slide animations from Radix.
 */
export function ActionDrawer({ title, actions, onPick, onClose, onSelectMore, extra }: Props) {
	const { t } = useT();
	// Dismissing slides the sheet away before the caller unmounts it. A pick
	// closes at once: its action (Rename's input, say) should not wait on an
	// animation.
	const [open, setOpen] = useState(true);
	useEffect(() => {
		if (open) {
			return;
		}
		const id = setTimeout(onClose, CLOSE_MS);
		return () => clearTimeout(id);
	}, [open, onClose]);

	// A pick hands focus to whatever it opens (Rename's input). Radix would
	// restore it to the kebab as the sheet unmounts, blurring that input and
	// cancelling the rename, so a pick skips the restore.
	const picked = useRef(false);
	const pick = (run: () => void) => () => {
		picked.current = true;
		run();
		onClose();
	};
	const del = actions.findIndex((a) => a.destructive);
	const extraAt = del === -1 ? actions.length : del;
	const extraRow = extra ? (
		<Fragment key="extra">
			{extraAt > 0 ? <hr className="mx-4 my-1 border-border border-t" /> : null}
			<button type="button" role="menuitem" onClick={pick(extra.onSelect)} className={ROW}>
				<extra.icon aria-hidden="true" className="size-4 shrink-0" />
				{extra.label}
			</button>
		</Fragment>
	) : null;

	const rows: ReactNode[] = actions.map((a, i) => {
		const Icon = ACTION_ICONS[a.id];
		return (
			<Fragment key={a.id}>
				{startsGroup(a, i) ? <hr className="mx-4 my-1 border-border border-t" /> : null}
				<button
					type="button"
					role="menuitem"
					onClick={pick(() => onPick(a.id))}
					className={`${ROW} ${a.destructive ? "text-destructive" : ""}`}
				>
					{/* aria-hidden so the menuitem's accessible name stays the label */}
					<Icon aria-hidden="true" className="size-4 shrink-0" />
					{a.translated ? a.label : t(a.label)}
				</button>
			</Fragment>
		);
	});
	rows.splice(extraAt, 0, extraRow);

	return (
		<Sheet open={open} onOpenChange={setOpen}>
			<SheetContent
				side="bottom"
				showCloseButton={false}
				data-testid="action-drawer"
				onCloseAutoFocus={(e) => {
					if (picked.current) {
						e.preventDefault();
					}
				}}
				className="gap-0 rounded-t-2xl border-t-0 pb-[env(safe-area-inset-bottom)] text-base"
			>
				<div aria-hidden="true" className="mx-auto my-2 h-1 w-10 rounded-full bg-border" />
				<SheetTitle className="truncate px-4 py-2 font-medium text-sm">{title}</SheetTitle>
				<SheetDescription className="sr-only">{t("Actions")}</SheetDescription>
				<div role="menu" aria-label={title}>
					{rows}
					{onSelectMore ? (
						<button
							type="button"
							onClick={pick(onSelectMore)}
							className={`${ROW} border-border border-t`}
						>
							<ListChecks aria-hidden="true" className="size-4 shrink-0" />
							{t("Select more")}
						</button>
					) : null}
				</div>
			</SheetContent>
		</Sheet>
	);
}

import { ListChecks } from "lucide-react";
import { Fragment, useEffect, useState } from "react";
import { createPortal } from "react-dom";
import { useT } from "@/i18n/locale-provider";
import { cn } from "@/lib/utils";
import { ACTION_ICONS, type Action, type ActionId, startsGroup } from "./action-list";

interface Props {
	title: string;
	actions: readonly Action[];
	onPick: (id: ActionId) => void;
	onClose: () => void;
	onSelectMore?: () => void;
}

/** How long the sheet takes to slide out. Matches `duration-200` below. */
export const CLOSE_MS = 200;

export function ActionDrawer({ title, actions, onPick, onClose, onSelectMore }: Props) {
	const { t } = useT();
	// Tapping out slides the sheet away before it unmounts. A pick still closes
	// at once: its action (Rename's input, say) should not wait on an animation.
	const [closing, setClosing] = useState(false);
	useEffect(() => {
		if (!closing) {
			return;
		}
		const id = setTimeout(onClose, CLOSE_MS);
		return () => clearTimeout(id);
	}, [closing, onClose]);
	// Portalled, like every other overlay: the note menu mounts this inside the
	// mobile header, whose button styles and stacking context must not reach it.
	return createPortal(
		<>
			<button
				type="button"
				aria-label={t("Close menu")}
				data-testid="action-drawer-backdrop"
				onClick={() => setClosing(true)}
				className={cn(
					"fixed inset-0 z-40 bg-black/40 duration-200",
					closing ? "fade-out-0 animate-out fill-mode-forwards" : "fade-in-0 animate-in",
				)}
			/>
			<div
				role="menu"
				className={cn(
					"fixed inset-x-0 bottom-0 z-50 rounded-t-2xl bg-popover text-popover-foreground duration-200",
					closing
						? "slide-out-to-bottom animate-out fill-mode-forwards ease-in"
						: "slide-in-from-bottom animate-in ease-out",
				)}
			>
				<div className="mx-auto my-2 h-1 w-10 rounded-full bg-border" />
				<p className="truncate px-4 py-2 font-medium text-sm">{title}</p>
				{actions.map((a, i) => {
					const Icon = ACTION_ICONS[a.id];
					return (
						<Fragment key={a.id}>
							{startsGroup(a, i) ? <hr className="mx-4 my-1 border-border border-t" /> : null}
							<button
								type="button"
								role="menuitem"
								onClick={() => {
									onPick(a.id);
									onClose();
								}}
								className={`flex w-full items-center gap-3 px-4 py-3 text-left text-base ${
									a.destructive ? "text-destructive" : ""
								}`}
							>
								{/* aria-hidden so the menuitem's accessible name stays the label */}
								<Icon aria-hidden="true" className="size-4 shrink-0" />
								{a.translated ? a.label : t(a.label)}
							</button>
						</Fragment>
					);
				})}
				{onSelectMore ? (
					<button
						type="button"
						onClick={() => {
							onSelectMore();
							onClose();
						}}
						className="flex w-full items-center gap-3 border-border border-t px-4 py-3 text-left text-base"
					>
						<ListChecks aria-hidden="true" className="size-4 shrink-0" />
						{t("Select more")}
					</button>
				) : null}
			</div>
		</>,
		document.body,
	);
}

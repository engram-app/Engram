import { ListChecks } from "lucide-react";
import { ACTION_ICONS, type Action, type ActionId } from "./action-list";

interface Props {
	title: string;
	actions: readonly Action[];
	onPick: (id: ActionId) => void;
	onClose: () => void;
	onSelectMore?: () => void;
}

export function ActionDrawer({ title, actions, onPick, onClose, onSelectMore }: Props) {
	return (
		<>
			<button
				type="button"
				aria-label="Close menu"
				data-testid="action-drawer-backdrop"
				onClick={onClose}
				className="fixed inset-0 z-40 bg-black/40"
			/>
			<div
				role="menu"
				className="fixed inset-x-0 bottom-0 z-50 rounded-t-2xl bg-popover text-popover-foreground"
			>
				<div className="mx-auto my-2 h-1 w-10 rounded-full bg-border" />
				<p className="truncate px-4 py-2 font-medium text-sm">{title}</p>
				{actions.map((a) => {
					const Icon = ACTION_ICONS[a.id];
					return (
						<button
							key={a.id}
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
							{a.label}
						</button>
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
						Select more
					</button>
				) : null}
			</div>
		</>
	);
}

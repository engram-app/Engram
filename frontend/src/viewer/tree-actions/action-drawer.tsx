import type { Action, ActionId } from "./action-list";

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
			<div
				data-testid="action-drawer-backdrop"
				onClick={onClose}
				className="fixed inset-0 z-40 bg-black/40"
			/>
			<div
				role="menu"
				className="fixed inset-x-0 bottom-0 z-50 rounded-t-2xl bg-white dark:bg-gray-900"
			>
				<div className="mx-auto my-2 h-1 w-10 rounded-full bg-gray-300 dark:bg-gray-700" />
				<p className="truncate px-4 py-2 font-medium text-gray-700 text-sm dark:text-gray-200">
					{title}
				</p>
				{actions.map((a) => (
					<button
						key={a.id}
						type="button"
						role="menuitem"
						onClick={() => {
							onPick(a.id);
							onClose();
						}}
						className={`flex w-full px-4 py-3 text-left text-base ${
							a.destructive ? "text-red-600 dark:text-red-400" : "text-gray-800 dark:text-gray-100"
						}`}
					>
						{a.label}
					</button>
				))}
				{onSelectMore && (
					<button
						type="button"
						onClick={() => {
							onSelectMore();
							onClose();
						}}
						className="flex w-full border-gray-200 border-t px-4 py-3 text-left text-base text-gray-800 dark:border-gray-700 dark:text-gray-100"
					>
						Select more
					</button>
				)}
			</div>
		</>
	);
}

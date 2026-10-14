import { MoreVertical } from "lucide-react";
import { Fragment, useState } from "react";
import { Button } from "@/components/ui/button";
import {
	DropdownMenu,
	DropdownMenuContent,
	DropdownMenuItem,
	DropdownMenuSeparator,
	DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useMediaQuery } from "@/hooks/use-media-query";
import { useT } from "@/i18n/locale-provider";
import { msg } from "@/i18n/msg";
import { useMobileHeaderSlot } from "@/layout/mobile-header-slot";
import { ActionDrawer } from "./tree-actions/action-drawer";
import {
	ACTION_ICONS,
	type ActionId,
	noteMenuActions,
	startsGroup,
	type ViewMode,
} from "./tree-actions/action-list";

interface Props {
	mode: ViewMode;
	/** Shown as the drawer's heading on mobile. */
	title: string;
	onPick: (id: ActionId) => void;
}

/**
 * The note page's kebab. Desktop gets a dropdown; mobile gets the same
 * bottom-sheet the file tree already uses on long-press, so the two menu
 * surfaces in the app behave identically on touch.
 */
export function NoteMenu({ mode, title, onPick }: Props) {
	const { t } = useT();
	const isDesktop = useMediaQuery("(min-width: 768px)");
	const [drawerOpen, setDrawerOpen] = useState(false);
	const actions = noteMenuActions(mode);
	const openTools = useMobileHeaderSlot()?.openTools;

	if (!isDesktop) {
		// The mobile header has no tools button; its drawer opens from here,
		// just above the destructive action so Delete stays last.
		const del = actions.findIndex((a) => a.destructive);
		const mobileActions = openTools
			? [
					...actions.slice(0, del),
					{ id: "open-tools" as const, label: msg("Open tools") },
					...actions.slice(del),
				]
			: actions;
		return (
			<>
				<Button
					variant="ghost"
					size="icon"
					aria-label={t("Note options")}
					onClick={() => setDrawerOpen(true)}
				>
					<MoreVertical className="size-4" />
				</Button>
				{drawerOpen ? (
					<ActionDrawer
						title={title}
						actions={mobileActions}
						onPick={(id) => (id === "open-tools" ? openTools?.() : onPick(id))}
						onClose={() => setDrawerOpen(false)}
					/>
				) : null}
			</>
		);
	}

	return (
		// modal={false} turns OFF Radix's focus trap. With it on, "Rename" opened
		// the inline title's input, the still-mounted trap yanked focus back into
		// the menu, and RenameInput's commit-or-cancel-on-blur closed the box in
		// the same tick — rename from the kebab was unusable. A kebab does not
		// need to trap focus or lock scroll.
		<DropdownMenu modal={false}>
			<DropdownMenuTrigger asChild>
				<Button variant="ghost" size="icon" aria-label={t("Note options")}>
					<MoreVertical className="size-4" />
				</Button>
			</DropdownMenuTrigger>
			<DropdownMenuContent align="end">
				{actions.map((action, i) => {
					const Icon = ACTION_ICONS[action.id];
					return (
						<Fragment key={action.id}>
							{startsGroup(action, i) ? <DropdownMenuSeparator /> : null}
							<DropdownMenuItem
								// aria-current rather than a checkbox item: the modes are a
								// single-select group, and this keeps one code path for
								// every row in the menu.
								aria-current={action.active ? "true" : undefined}
								variant={action.destructive ? "destructive" : "default"}
								onSelect={() => onPick(action.id)}
							>
								<Icon aria-hidden="true" className="size-4" />
								{action.translated ? action.label : t(action.label)}
							</DropdownMenuItem>
						</Fragment>
					);
				})}
			</DropdownMenuContent>
		</DropdownMenu>
	);
}

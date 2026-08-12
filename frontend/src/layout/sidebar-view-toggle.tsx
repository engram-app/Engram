import { FolderTree, Search } from "lucide-react";
import { type RailView, useRailView } from "./rail-view-context";

const VIEWS: ReadonlyArray<{ id: RailView; label: string; Icon: typeof Search }> = [
	{ id: "files", label: "Files", Icon: FolderTree },
	{ id: "search", label: "Search", Icon: Search },
];

/**
 * Picks which panel fills the mobile drawer, the way the rail's top group does
 * on desktop.
 *
 * Mobile has no rail — it is a drawer, and the icon strip has nowhere to live —
 * so without this the search panel was simply unreachable on a phone. Obsidian
 * solves it the same way: a row of view tabs inside the drawer itself.
 *
 * Labelled, not icon-only. The rail can afford bare icons because it is
 * permanently visible and you learn it once; a row you meet inside a drawer has
 * to say what it does.
 */
export default function SidebarViewToggle() {
	const { view, setView } = useRailView();
	return (
		<nav
			aria-label="Sidebar views"
			className="flex shrink-0 border-border border-t bg-card [&>button]:h-11"
		>
			{VIEWS.map(({ id, label, Icon }) => {
				const active = view === id;
				return (
					<button
						key={id}
						type="button"
						// aria-current, matching the rail: these mark which panel is
						// showing, they do not toggle something open and shut.
						aria-current={active ? "page" : undefined}
						onClick={() => setView(id)}
						className={`flex flex-1 items-center justify-center gap-2 font-medium text-sm transition-colors ${
							active
								? "bg-primary/15 text-primary"
								: "text-muted-foreground hover:bg-primary/10 hover:text-primary"
						}`}
					>
						<Icon className="size-4" />
						{label}
					</button>
				);
			})}
		</nav>
	);
}

import { Menu, PanelRightOpen, X } from "lucide-react";
import { type MouseEvent, useEffect, useState } from "react";
import { Link, Outlet, useLocation } from "react-router";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import {
	Sheet,
	SheetClose,
	SheetContent,
	SheetDescription,
	SheetTitle,
	SheetTrigger,
} from "@/components/ui/sheet";
import FolderTree from "../viewer/folder-tree";
import FolderActions from "./folder-actions";
import { FolderTreeProvider } from "./folder-tree-context";
import { useRailView } from "./rail-view-context";
import RightToolPanel from "./right-tool-panel";
import { RIGHT_TOOLS, useRightTools } from "./right-tools-context";
import SearchPanel from "./search-panel";
import SidebarViewToggle from "./sidebar-view-toggle";
import UserMenu from "./user-menu";
import VaultSwitcher from "./vault-switcher";

// Close the drawer only when the click originated on a navigation link.
// Buttons (e.g. folder-expand toggles in FolderTree) must keep the drawer open.
function closeOnLinkClick(close: () => void) {
	return (event: MouseEvent<HTMLDivElement>) => {
		if ((event.target as HTMLElement).closest("a")) {
			close();
		}
	};
}

export default function MobileLayout() {
	const { resolvedId, setActive, isAvailable } = useRightTools();
	const { view } = useRailView();
	const [leftOpen, setLeftOpen] = useState(false);
	const [rightOpen, setRightOpen] = useState(false);
	const { pathname } = useLocation();

	// The drawer has no persistent rail to pick a tool from, so opening it with
	// none active would show an empty sheet. Fall back to the first usable tool
	// ("reference" always qualifies).
	const openRight = () => {
		if (resolvedId === null) {
			setActive(RIGHT_TOOLS.find((tool) => isAvailable(tool.id))?.id ?? "reference");
		}
		setRightOpen(true);
	};

	// Programmatic navigations (e.g. clicking "New note" in FolderActions) don't
	// trigger closeOnLinkClick. Close both drawers on any route change so the
	// editor isn't hidden behind a still-open sheet on small screens.
	// biome-ignore lint/correctness/useExhaustiveDependencies: pathname is a change trigger, not a captured value (the effect only calls setters); keying on it is required to close both drawers on navigation.
	useEffect(() => {
		setLeftOpen(false);
		setRightOpen(false);
	}, [pathname]);

	return (
		<section className="flex h-dvh flex-col bg-background text-foreground">
			<header className="sticky top-0 z-20 flex shrink-0 items-center justify-between border-border border-b bg-card p-2">
				<section className="flex items-center gap-1">
					<Sheet open={leftOpen} onOpenChange={setLeftOpen}>
						<SheetTrigger asChild>
							<Button variant="ghost" size="icon" aria-label="Open files" className="size-11">
								<Menu />
							</Button>
						</SheetTrigger>
						<SheetContent
							side="left"
							showCloseButton={false}
							className="flex flex-col gap-0 p-0 data-[side=left]:w-[85vw] sm:max-w-none"
						>
							<FolderTreeProvider>
								<section className="flex shrink-0 items-center justify-between border-border border-b px-3 py-2">
									<SheetTitle className="font-medium text-base">
										{view === "search" ? "Search" : "Files"}
									</SheetTitle>
									<SheetDescription className="sr-only">
										{view === "search" ? "Search your notes" : "Folder navigation"}
									</SheetDescription>
									<SheetClose asChild>
										<Button variant="ghost" size="icon-sm" aria-label="Close">
											<X />
										</Button>
									</SheetClose>
								</section>
								{view === "search" ? (
									// onNavigate rather than the closeOnLinkClick delegation used
									// for the tree: the handler belongs on the link itself, and
									// that also covers tapping the result for the note you are
									// ALREADY on, where the route never changes and the
									// pathname effect below never fires.
									<SearchPanel hideHeader onNavigate={() => setLeftOpen(false)} />
								) : (
									<>
										<ScrollArea
											className="min-h-0 flex-1"
											onClick={closeOnLinkClick(() => setLeftOpen(false))}
										>
											<FolderTree />
										</ScrollArea>
										{/* New note / new folder belong to the files view only. */}
										<FolderActions />
									</>
								)}
								<SidebarViewToggle />
								<VaultSwitcher />
							</FolderTreeProvider>
						</SheetContent>
					</Sheet>
					<Link to="/" className="font-semibold text-base text-foreground">
						Engram
					</Link>
				</section>
				<nav className="flex items-center gap-1" aria-label="Main navigation">
					<UserMenu />
					{/* Always available now — the reference tool is valid on every route,
					    unlike the outline this drawer used to be gated on. */}
					<Sheet open={rightOpen} onOpenChange={setRightOpen}>
						<SheetTrigger asChild>
							<Button
								variant="ghost"
								size="icon"
								aria-label="Open tools"
								className="size-11"
								onClick={openRight}
							>
								<PanelRightOpen />
							</Button>
						</SheetTrigger>
						<SheetContent
							side="right"
							showCloseButton={false}
							className="flex flex-col gap-0 p-0 data-[side=right]:w-[85vw] sm:max-w-none"
							onClick={closeOnLinkClick(() => setRightOpen(false))}
						>
							<SheetTitle className="sr-only">Sidebar tools</SheetTitle>
							<SheetDescription className="sr-only">
								Note outline and markdown reference
							</SheetDescription>
							<RightToolPanel onCollapse={() => setRightOpen(false)} />
						</SheetContent>
					</Sheet>
				</nav>
			</header>
			<main className="flex-1 overflow-y-auto bg-muted/40 text-foreground">
				<Outlet />
			</main>
		</section>
	);
}

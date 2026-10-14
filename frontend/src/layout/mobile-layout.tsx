import { PanelLeftOpen, X } from "lucide-react";
import { type MouseEvent, useEffect, useState } from "react";
import { Outlet, useLocation } from "react-router";
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
import { useT } from "@/i18n/locale-provider";
import { LegalNoticeBanner } from "../legal/legal-notice-banner";
import FolderTree from "../viewer/folder-tree";
import FolderActions from "./folder-actions";
import { FolderTreeProvider } from "./folder-tree-context";
import LazySearchPanel from "./lazy-search-panel";
import { MobileHeaderSlot } from "./mobile-header-slot";
import { useRailView } from "./rail-view-context";
import RightToolPanel from "./right-tool-panel";
import { RIGHT_TOOLS, useRightTools } from "./right-tools-context";
import SidebarViewToggle from "./sidebar-view-toggle";
import UserMenu from "./user-menu";
import VaultSwitcher from "./vault-switcher";

// The grey chip under the header's buttons, so passing text never runs under
// a bare glyph. Not the page background colour, or it would vanish.
const CHIP = "rounded-md bg-secondary/90";

// Close the drawer only when the click originated on a navigation link.
// Buttons (e.g. folder-expand toggles in FolderTree) must keep the drawer open.
function closeOnLinkClick(close: () => void) {
	return (event: MouseEvent<HTMLDivElement>) => {
		if (event.target instanceof Element && event.target.closest("a")) {
			close();
		}
	};
}

export default function MobileLayout() {
	const { t } = useT();
	const { resolvedId, setActive, isAvailable } = useRightTools();
	const { view } = useRailView();
	const [leftOpen, setLeftOpen] = useState(false);
	const [rightOpen, setRightOpen] = useState(false);
	const [actionSlot, setActionSlot] = useState<HTMLElement | null>(null);
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
		// biome-ignore lint/nursery/useReactCompiler: closing the drawers is a reaction to navigation, which has no render-phase form -- programmatic navigations (FolderActions' "New note") never pass through the click handler, and keying the Sheets on pathname would remount FolderTree on every route change.
		setLeftOpen(false);
		setRightOpen(false);
	}, [pathname]);

	return (
		<section className="flex h-dvh flex-col bg-background text-foreground [--mobile-header:3.5rem]">
			{/* Above the floating header, in flow, so the header never covers it. */}
			<LegalNoticeBanner />
			<div className="relative flex min-h-0 flex-1 flex-col">
				{/* Obsidian-style: no title bar, just the corner buttons floating over
			    the page, so text scrolls past behind them. The icons sit on small
			    grey chips (the page's own actions share one), so passing text never
			    runs under a bare glyph. The tools drawer has no button here; the
			    note menu opens it (MobileHeaderSlot.openTools).
			    --mobile-header is its height: main pads by it, and a note's
			    surface bleeds up under it (note-page.tsx).
			    The bar itself lets touches through to the text behind it; only
			    its buttons take them. Every button in it, the page's portalled
			    actions included, is sized here so the corners match. */}
				<header className="pointer-events-none absolute inset-x-0 top-0 z-20 flex h-(--mobile-header) items-end justify-between px-2 *:pointer-events-auto [&_button]:size-11 [&_button_svg]:size-5.5">
					<Sheet open={leftOpen} onOpenChange={setLeftOpen}>
						<SheetTrigger asChild>
							<Button variant="ghost" size="icon-lg" aria-label={t("Open files")} className={CHIP}>
								<PanelLeftOpen />
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
										{view === "search" ? t("Search") : t("Files")}
									</SheetTitle>
									<SheetDescription className="sr-only">
										{view === "search" ? t("Search your notes") : t("Folder navigation")}
									</SheetDescription>
									<SheetClose asChild>
										<Button variant="ghost" size="icon-sm" aria-label={t("Close")}>
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
									<LazySearchPanel hideHeader onNavigate={() => setLeftOpen(false)} />
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
								{/* Account sits at the end of the vault row, where Obsidian mobile
							    keeps its settings gear: no extra row under the tree. The row
							    owns the seam, so the switcher drops its own. */}
								<section className="flex items-center gap-1 border-border border-t pr-2">
									<VaultSwitcher className="min-w-0 flex-1 border-t-0" />
									<UserMenu />
								</section>
							</FolderTreeProvider>
						</SheetContent>
					</Sheet>
					{/* The page's own actions (reading toggle, note menu), portalled in;
				    they share one chip. */}
					<fieldset
						ref={setActionSlot}
						aria-label={t("Page actions")}
						className={`flex items-center empty:hidden ${CHIP}`}
					/>
					<Sheet open={rightOpen} onOpenChange={setRightOpen}>
						<SheetContent
							side="right"
							showCloseButton={false}
							className="flex flex-col gap-0 p-0 data-[side=right]:w-[85vw] sm:max-w-none"
							onClick={closeOnLinkClick(() => setRightOpen(false))}
						>
							<SheetTitle className="sr-only">{t("Sidebar tools")}</SheetTitle>
							<SheetDescription className="sr-only">
								{t("Note outline and markdown reference")}
							</SheetDescription>
							<RightToolPanel onCollapse={() => setRightOpen(false)} />
						</SheetContent>
					</Sheet>
				</header>
				<main className="flex-1 overflow-y-auto bg-muted/40 pt-(--mobile-header) text-foreground">
					<MobileHeaderSlot.Provider value={{ slot: actionSlot, openTools: openRight }}>
						<Outlet />
					</MobileHeaderSlot.Provider>
				</main>
			</div>
		</section>
	);
}

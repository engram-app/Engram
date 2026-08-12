import { useEffect } from "react";
import { useDefaultLayout, usePanelRef } from "react-resizable-panels";
import { Outlet } from "react-router";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/components/ui/resizable";
import { useMediaQuery } from "@/hooks/use-media-query";
import { useBillingStatus } from "../api/queries";
import { useChannel } from "../api/use-channel";
import { AttachmentUploadProvider } from "../viewer/attachment-upload/provider";
import { ActiveEditorProvider } from "../viewer/editor/active-editor-context";
import { preloadNoteChunks } from "../viewer/note-chunks";
import AppSidebarPanel, { Rail } from "./app-sidebar";
import MobileLayout from "./mobile-layout";
import { RailViewProvider } from "./rail-view-context";
import RightToolPanel from "./right-tool-panel";
import { RightToolsProvider, useRightTools } from "./right-tools-context";

const LAYOUT_PANEL_IDS = ["sidebar", "main", "right-sidebar"];

function DesktopLayout() {
	const rightRef = usePanelRef();
	const { resolvedId, setActive } = useRightTools();
	const { defaultLayout, onLayoutChanged } = useDefaultLayout({
		id: "engram:app-layout-v2",
		panelIds: LAYOUT_PANEL_IDS,
		storage: typeof window === "undefined" ? undefined : window.localStorage,
	});

	// The active tool IS the open/closed state — there is no separate collapsed
	// flag to keep in sync. Collapsing the panel clears the tool (and persists
	// that); picking a tool from the rail re-expands it.
	// biome-ignore lint/correctness/useExhaustiveDependencies: rightRef.current exposes imperative panel handles, not reactive values; the effect intentionally keys on resolvedId alone.
	useEffect(() => {
		if (resolvedId === null) {
			rightRef.current?.collapse();
		} else if (rightRef.current?.isCollapsed()) {
			rightRef.current?.expand();
		}
	}, [resolvedId]);

	return (
		<section className="flex h-screen bg-background text-foreground">
			<Rail />
			<ResizablePanelGroup
				orientation="horizontal"
				defaultLayout={defaultLayout}
				onLayoutChanged={onLayoutChanged}
				className="flex-1"
			>
				<ResizablePanel
					id="sidebar"
					defaultSize="240px"
					// The FolderActions row is 5 × size-10 icon buttons = 200px of
					// intrinsic width, and this panel's border-r takes 1px off the
					// content box. Anything narrower clips the right-hand buttons, so
					// this floor is measured, not a taste call.
					minSize="201px"
					maxSize="480px"
					className="border-border border-r bg-card"
				>
					<AppSidebarPanel />
				</ResizablePanel>
				<ResizableHandle />
				<ResizablePanel id="main" defaultSize="60%" minSize="30%">
					<main className="relative flex h-full flex-col overflow-hidden bg-muted/40 text-foreground">
						{/* Brand grid texture on the muted backdrop, behind the centered
                document card. No corner glows — grid only. */}
						<div
							aria-hidden="true"
							className="grid-overlay pointer-events-none absolute inset-0 z-0 opacity-30"
						/>
						<TrialBanner />
						{/* No floating expand button: the rail's tool group is now the one
						    discoverable way to open this panel, for every tool. */}
						<div className="relative z-10 flex-1 overflow-hidden p-6">
							<Outlet />
						</div>
					</main>
				</ResizablePanel>
				<ResizableHandle />
				<ResizablePanel
					id="right-sidebar"
					panelRef={rightRef}
					defaultSize="22%"
					minSize="12%"
					maxSize="40%"
					collapsible
					collapsedSize="0%"
					// Dragging the panel shut is the same gesture as clicking Collapse,
					// so it clears the active tool rather than leaving the two out of sync.
					onResize={(size) => {
						if (size.asPercentage === 0 && resolvedId !== null) {
							setActive(null);
						}
					}}
					className="border-border border-l bg-card"
				>
					<RightToolPanel onCollapse={() => setActive(null)} />
				</ResizablePanel>
			</ResizablePanelGroup>
		</section>
	);
}

function TrialBanner() {
	const { data: billing } = useBillingStatus();
	const days = billing?.trial_days_remaining ?? 0;
	if (billing?.subscription?.status !== "trialing" || days <= 0 || days > 3) {
		return null;
	}
	return (
		<aside
			className="bg-amber-50 px-4 py-2 text-center text-amber-900 text-sm dark:bg-amber-950/40 dark:text-amber-100"
			role="alert"
		>
			{days} days left in your trial.
		</aside>
	);
}

function AppLayoutInner() {
	useChannel();
	const isDesktop = useMediaQuery("(min-width: 768px)");
	return isDesktop ? <DesktopLayout /> : <MobileLayout />;
}

export default function AppLayout() {
	// Warm the note-viewing chunks while the user is still looking at the tree.
	// Opening the first note otherwise walks three lazy boundaries in series,
	// two of them behind a full-pane spinner (#1317). requestIdleCallback so it
	// never competes with the initial render; setTimeout for Safari, which
	// still lacks it.
	useEffect(() => {
		// Respect an explicit data-saver signal and genuinely slow links: the
		// editor chunk alone is ~1.3 MB, and a user who signed in to check
		// billing or settings never opens a note. On a slow link the preload
		// would also contend with the bootstrap/vault-tree requests that gate
		// the sidebar, making the tree paint LATER for exactly those users.
		const conn = (
			navigator as Navigator & {
				connection?: { saveData?: boolean; effectiveType?: string };
			}
		).connection;
		if (conn?.saveData || conn?.effectiveType === "slow-2g" || conn?.effectiveType === "2g") {
			return;
		}

		const idle = window.requestIdleCallback;
		if (typeof idle === "function") {
			const handle = idle(() => preloadNoteChunks());
			return () => window.cancelIdleCallback?.(handle);
		}
		const timer = setTimeout(preloadNoteChunks, 0);
		return () => clearTimeout(timer);
	}, []);

	return (
		<RightToolsProvider>
			<RailViewProvider>
				<AttachmentUploadProvider>
					{/* Must wrap BOTH the right sidebar and the <Outlet/> below it — the
					    note page publishes its editor here, the sidebar tools consume it. */}
					<ActiveEditorProvider>
						<AppLayoutInner />
					</ActiveEditorProvider>
				</AttachmentUploadProvider>
			</RailViewProvider>
		</RightToolsProvider>
	);
}

import { PanelRightClose, PanelRightOpen } from "lucide-react";
import { useEffect } from "react";
import { useDefaultLayout, usePanelRef } from "react-resizable-panels";
import { Outlet } from "react-router";
import { Button } from "@/components/ui/button";
import { ResizableHandle, ResizablePanel, ResizablePanelGroup } from "@/components/ui/resizable";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useMediaQuery } from "@/hooks/use-media-query";
import { useBillingStatus } from "../api/queries";
import { useChannel } from "../api/use-channel";
import AppSidebarPanel, { Rail } from "./app-sidebar";
import MobileLayout from "./mobile-layout";
import { RailViewProvider } from "./rail-view-context";
import { RightSidebarProvider, useRightSidebar } from "./right-sidebar-context";
import { AttachmentUploadProvider } from "../viewer/attachment-upload/provider";

const LAYOUT_PANEL_IDS = ["sidebar", "main", "right-sidebar"];

function DesktopLayout() {
	const rightRef = usePanelRef();
	const {
		content: rightContent,
		collapsed: rightCollapsed,
		setCollapsed: setRightCollapsed,
	} = useRightSidebar();
	const { defaultLayout, onLayoutChanged } = useDefaultLayout({
		id: "engram:app-layout-v2",
		panelIds: LAYOUT_PANEL_IDS,
		storage: typeof window === "undefined" ? undefined : window.localStorage,
	});

	const toggleRight = () => {
		const p = rightRef.current;
		if (!p) return;
		if (p.isCollapsed()) p.expand();
		else p.collapse();
	};

	useEffect(() => {
		if (rightContent == null) rightRef.current?.collapse();
		else if (rightRef.current?.isCollapsed()) rightRef.current?.expand();
	}, [rightContent]);

	const hasRight = rightContent != null;

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
					minSize="180px"
					maxSize="480px"
					className="border-r border-border bg-card"
				>
					<AppSidebarPanel />
				</ResizablePanel>
				<ResizableHandle />
				<ResizablePanel id="main" defaultSize="60%" minSize="30%">
					<main
						className="relative flex h-full flex-col overflow-hidden bg-muted/40 text-foreground"
						data-tour="note-viewer"
					>
						{/* Brand grid texture on the muted backdrop, behind the centered
                document card. No corner glows — grid only. */}
						<div
							aria-hidden="true"
							className="grid-overlay pointer-events-none absolute inset-0 z-0 opacity-30"
						/>
						<TrialBanner />
						{hasRight && rightCollapsed && (
							<Button
								variant="ghost"
								size="icon-sm"
								onClick={toggleRight}
								aria-label="Expand outline"
								title="Expand outline"
								className="absolute right-2 top-2 z-10 bg-card/80 backdrop-blur"
							>
								<PanelRightOpen />
							</Button>
						)}
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
					onResize={(size) => setRightCollapsed(size.asPercentage === 0)}
					className="border-l border-border bg-card"
				>
					<div className="flex h-full flex-col">
						<div className="flex shrink-0 items-center justify-start border-b border-border px-1 py-1">
							<Button
								variant="ghost"
								size="icon-sm"
								onClick={toggleRight}
								aria-label="Collapse outline"
								title="Collapse outline"
							>
								<PanelRightClose />
							</Button>
						</div>
						<ScrollArea className="flex-1">{rightContent}</ScrollArea>
					</div>
				</ResizablePanel>
			</ResizablePanelGroup>
		</section>
	);
}

function TrialBanner() {
	const { data: billing } = useBillingStatus();
	const days = billing?.trial_days_remaining ?? 0;
	if (billing?.subscription?.status !== "trialing" || days <= 0 || days > 3) return null;
	return (
		<aside
			className="bg-amber-50 px-4 py-2 text-center text-sm text-amber-900 dark:bg-amber-950/40 dark:text-amber-100"
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
	return (
		<RightSidebarProvider>
			<RailViewProvider>
				<AttachmentUploadProvider>
					<AppLayoutInner />
				</AttachmentUploadProvider>
			</RailViewProvider>
		</RightSidebarProvider>
	);
}

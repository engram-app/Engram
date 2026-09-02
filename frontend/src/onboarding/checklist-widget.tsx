import { useQueryClient } from "@tanstack/react-query";
import { Waypoints } from "lucide-react";
import { useState } from "react";
import { Link } from "react-router";
import { useMediaQuery } from "@/hooks/use-media-query";
import { type OnboardingStatus, useConnections, useOnboardingStatus } from "../api/queries";
import { useIsFreeTier } from "../billing/use-is-free-tier";
import { Button } from "../components/ui/button";
import {
	Sheet,
	SheetContent,
	SheetDescription,
	SheetHeader,
	SheetTitle,
} from "../components/ui/sheet";
import { Shimmer } from "../components/ui/shimmer";
import { DISCORD_INVITE_URL } from "../settings/account/community-section";
import { useOnboardingActions } from "./use-onboarding-actions";

interface Item {
	key: string;
	label: string;
	// `done` = genuinely completed (vault created, MCP/obsidian connection
	// resolved). Completed rows stay visible, struck through. Dismissal is a
	// separate user action (`dismissed`) that removes the row entirely.
	done: boolean;
	dismissed?: boolean;
	docUrl?: string;
	/** Text on the row's link button. Defaults to "Setup guide" — override when
	 *  the destination is not a guide (Discord is an invite, not instructions). */
	actionLabel?: string;
	dismissible?: boolean;
}

// Every selectable slug in the FTUX catalog (onboarding-tools.ts) must have an
// entry here, or its row silently renders the generic index instead of its own
// guide (#1157). Exported at the foot of the file for the parity test.
const DOC_URLS: Record<string, string> = {
	install_obsidian_plugin: "https://engram.page/docs/obsidian/install/",
	claude: "https://engram.page/docs/integrations/claude-desktop/",
	cursor: "https://engram.page/docs/integrations/cursor/",
	devin: "https://engram.page/docs/integrations/devin/",
	claude_code: "https://engram.page/docs/integrations/claude-code/",
	chatgpt: "https://engram.page/docs/integrations/chatgpt/",
	grok: "https://engram.page/docs/integrations/grok/",
	mistral: "https://engram.page/docs/integrations/mistral/",
	open_webui: "https://engram.page/docs/integrations/open-webui/",
	lobechat: "https://engram.page/docs/integrations/lobechat/",
	windsurf: "https://engram.page/docs/integrations/windsurf/",
	cline: "https://engram.page/docs/integrations/cline/",
	continue: "https://engram.page/docs/integrations/continue/",
	opencode: "https://engram.page/docs/integrations/opencode/",
	github_copilot: "https://engram.page/docs/integrations/github-copilot/",
	antigravity: "https://engram.page/docs/integrations/antigravity/",
	other_mcp: "https://engram.page/docs/mcp/manual-config/",
};
const DOC_FALLBACK = "https://engram.page/docs/integrations/";

const TOOL_LABELS: Record<string, string> = {
	claude: "Connect Claude Desktop",
	cursor: "Connect Cursor",
	devin: "Connect Devin",
	claude_code: "Connect Claude Code",
	chatgpt: "Connect ChatGPT",
	grok: "Connect Grok",
	mistral: "Connect Mistral",
	open_webui: "Connect Open WebUI",
	lobechat: "Connect LobeChat",
	windsurf: "Connect Devin Desktop (Windsurf)",
	cline: "Connect Cline",
	continue: "Connect Continue",
	opencode: "Connect OpenCode",
	github_copilot: "Connect GitHub Copilot",
	antigravity: "Connect Antigravity",
	other_mcp: "Connect another MCP client",
};

function ChecklistWidget() {
	// Same query app-layout and note-menu use, so this flips at exactly the
	// moment the app switches to MobileLayout.
	const isDesktop = useMediaQuery("(min-width: 768px)");
	// Mobile starts collapsed: throwing a bottom sheet over the app on load is
	// the "in the way" complaint at its worst. Desktop keeps opening expanded.
	const [collapsed, setCollapsed] = useState(() => !isDesktop);
	const ob = useOnboardingActions();
	const status = useOnboardingStatus();
	const profile = status.data?.profile;
	const connections = useConnections();
	const isFreeTier = useIsFreeTier();
	const qc = useQueryClient();

	if (ob.isLoading) {
		return null;
	}

	const actions = status.data?.actions ?? [];
	const dismissed = new Set(
		actions
			.filter((a): a is `dismissed:${string}` => a.startsWith("dismissed:"))
			.map((a) => a.slice("dismissed:".length)),
	);

	function dismiss(key: string) {
		const action = `dismissed:${key}` as const;

		// Optimistic cache update so the row vanishes immediately without
		// waiting for the mutation to round-trip. The mutation's onSuccess
		// invalidates this query, so the cache will be normalized from server.
		qc.setQueryData<OnboardingStatus>(["onboarding", "status"], (prev) => {
			if (!prev) {
				return prev;
			}
			if (prev.actions.includes(action)) {
				return prev;
			}
			return { ...prev, actions: [...prev.actions, action] };
		});

		ob.recordAsync(action).catch(() => {
			// The mutation hook already retries 3×, reaching here means the
			// server rejected. Roll back by invalidating so the next refetch
			// restores the real cache state.
			qc.invalidateQueries({ queryKey: ["onboarding", "status"] });
		});
	}

	const tools = (profile?.tools ?? []).filter((t) => t !== "web_only");
	const isDismissed = (key: string) => dismissed.has(key);
	const hasObsidianConnection = (connections.data ?? []).some((c) => c.kind === "obsidian");
	// A tool row auto-completes once a live MCP connection resolves to its slug
	// (backend LogoAllowlist matches claude.ai by redirect host).
	const connectedSlugs = new Set(
		(connections.data ?? [])
			.filter((c) => c.kind === "mcp")
			.map((c) => c.slug)
			.filter((s): s is string => Boolean(s)),
	);
	// `other_mcp` is the one row with no slug of its own, no client ever
	// resolves to it, so slug-matching left it permanently unstickable. It's
	// satisfied by any live MCP grant not already claimed by another row the
	// user picked (an unrecognized client has slug null and always counts).
	const otherSelected = new Set(tools.filter((t) => t !== "other_mcp"));
	const hasUnclaimedMcp = (connections.data ?? []).some(
		(c) => c.kind === "mcp" && !(c.slug && otherSelected.has(c.slug)),
	);

	const items: Item[] = [
		{
			key: "vault",
			label: "Create your first vault",
			done: ob.has("first_vault_created"),
		},
		{
			key: "join_discord",
			label: "Join our Discord",
			done: false,
			dismissed: isDismissed("join_discord"),
			docUrl: DISCORD_INVITE_URL,
			actionLabel: "Join",
			dismissible: true,
		},
		...(profile?.uses_obsidian
			? [
					{
						key: "install_obsidian_plugin",
						label: "Install the Obsidian plugin",
						done: hasObsidianConnection,
						dismissed: isDismissed("install_obsidian_plugin"),
						docUrl: DOC_URLS.install_obsidian_plugin,
						dismissible: true,
					} satisfies Item,
				]
			: []),
		...tools.map(
			(slug): Item => ({
				key: slug,
				label: TOOL_LABELS[slug] ?? `Connect ${slug}`,
				done: slug === "other_mcp" ? hasUnclaimedMcp : connectedSlugs.has(slug),
				dismissed: isDismissed(slug),
				docUrl: DOC_URLS[slug] ?? DOC_FALLBACK,
				dismissible: true,
			}),
		),
	];

	// Dismissed rows are removed entirely (the × is "hide this"). Completed rows
	// stay visible, struck through, so progress is felt, not silently erased.
	// The whole widget retires only once nothing is left to act on.
	const visible = items.filter((i) => !i.dismissed);
	const hasActionable = items.some((i) => !(i.done || i.dismissed));

	if (!hasActionable) {
		return null;
	}

	const total = items.length;
	const completed = items.filter((i) => i.done || i.dismissed).length;
	const pct = total === 0 ? 0 : Math.round((completed / total) * 100);
	const remaining = total - completed;

	if (collapsed) {
		// Mobile: a 44px touch target (the iOS floor) with a count, instead of a
		// pulsing full-width pill parked over the editor.
		return isDesktop ? (
			<Button
				type="button"
				size="lg"
				aria-label="Open setup checklist"
				className="fixed right-4 bottom-4 z-40 h-12 animate-surface-attention-pulse gap-2 overflow-hidden rounded-full px-5 text-base shadow-xl ring-1 ring-primary/30 [&_svg:not([class*='size-'])]:size-5"
				onClick={() => setCollapsed(false)}
			>
				<Waypoints aria-hidden />
				<span className="relative">Finish setup</span>
				<Shimmer gradient="from-transparent via-white/40 to-transparent" />
			</Button>
		) : (
			<Button
				type="button"
				size="icon"
				aria-label={`Open setup checklist, ${remaining} remaining`}
				// Rides above the editor toolbar when the keyboard is up. The var is
				// published by KeyboardBar and defaults to 0px, so this is exactly
				// bottom-4 everywhere else.
				className="fixed right-4 bottom-[calc(var(--editor-toolbar-offset,0px)+var(--spacing)*4)] z-40 size-11 rounded-full shadow-xl ring-1 ring-primary/30"
				onClick={() => setCollapsed(false)}
			>
				<Waypoints aria-hidden />
				<span className="absolute -top-1 -right-1 flex size-5 items-center justify-center rounded-full bg-background font-medium text-[11px] text-foreground ring-1 ring-border">
					{remaining}
				</span>
			</Button>
		);
	}

	const body = (
		<ChecklistBody
			visible={visible}
			total={total}
			completed={completed}
			pct={pct}
			isFreeTier={isFreeTier}
			onDismiss={dismiss}
		/>
	);

	if (!isDesktop) {
		return (
			<Sheet open onOpenChange={(next) => setCollapsed(!next)}>
				<SheetContent side="bottom" className="max-h-[80vh] gap-0 p-0">
					<SheetHeader className="border-border border-b">
						<SheetTitle className="text-base">Finish setup</SheetTitle>
						<SheetDescription className="sr-only">
							Steps left to finish setting up Engram
						</SheetDescription>
					</SheetHeader>
					{body}
				</SheetContent>
			</Sheet>
		);
	}

	return (
		<section
			aria-label="Onboarding checklist"
			// max-h + flex column so a long tool list scrolls inside the panel
			// rather than running off the bottom of the viewport.
			className="fixed right-4 bottom-4 z-40 flex max-h-[70vh] w-96 flex-col overflow-hidden rounded-xl border border-border bg-background shadow-xl ring-1 ring-primary/10"
		>
			<header className="relative flex flex-row items-center justify-between overflow-hidden border-border border-b px-4 py-3">
				<Shimmer />
				<h2 className="relative font-semibold text-base tracking-tight">Finish setup</h2>
				<button
					type="button"
					aria-label="Dismiss checklist"
					className="relative rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
					onClick={() => setCollapsed(true)}
				>
					×
				</button>
			</header>
			{body}
		</section>
	);
}

interface BodyProps {
	visible: Item[];
	total: number;
	completed: number;
	pct: number;
	isFreeTier: boolean;
	onDismiss: (key: string) => void;
}

/**
 * Progress + rows + free-tier note, shared by the desktop panel and the mobile
 * sheet so the two shells can't drift. Holds no state: everything it renders is
 * derived in ChecklistWidget.
 */
function ChecklistBody({ visible, total, completed, pct, isFreeTier, onDismiss }: BodyProps) {
	return (
		<>
			{total > 0 && (
				<div className="shrink-0 px-4 pt-3" aria-hidden>
					<div className="relative h-1.5 w-full overflow-hidden rounded-full bg-muted">
						<div
							className="h-full rounded-full bg-gradient-to-r from-primary/70 to-primary shadow-[0_0_8px_-1px_oklch(from_var(--primary)_l_c_h_/_0.6)] transition-[width] duration-700 ease-out"
							style={{ width: `${pct}%` }}
						/>
					</div>
					<p className="mt-1.5 text-muted-foreground text-xs">
						{completed} of {total} done
					</p>
				</div>
			)}
			{/* The scroll seam: min-h-0 lets this shrink inside the flex column so
			    the rows scroll instead of pushing the panel past its max height. */}
			<ul className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto p-4">
				{visible.map((i) => (
					<li key={i.key} className="flex items-center justify-between gap-2 text-sm">
						<span
							className={
								i.done
									? "flex items-center gap-2 text-muted-foreground line-through"
									: "flex items-center gap-2"
							}
						>
							<span aria-hidden>{i.done ? "☑" : "☐"}</span>
							{i.label}
						</span>
						{/* Completed rows carry no actions, just the checked-off label. */}
						{!i.done && (
							<span className="flex items-center gap-1">
								{i.docUrl ? (
									<Button asChild size="sm" variant="outline">
										<a href={i.docUrl} target="_blank" rel="noreferrer">
											{i.actionLabel ?? "Setup guide"} ↗
										</a>
									</Button>
								) : null}
								{Boolean(i.dismissible) && (
									<button
										type="button"
										aria-label={`Dismiss ${i.label}`}
										className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
										onClick={() => onDismiss(i.key)}
									>
										×
									</button>
								)}
							</span>
						)}
					</li>
				))}
			</ul>
			{isFreeTier ? (
				<p className="shrink-0 border-border border-t px-4 py-3 text-muted-foreground text-xs">
					You're on Free, 1 connection.{" "}
					<Link
						to="/onboard/billing"
						className="font-medium text-foreground underline underline-offset-4"
					>
						Upgrade
					</Link>
				</p>
			) : null}
		</>
	);
}

// Test-only surface for DOC_URLS. ChecklistWidget is exported here too rather
// than inline: ChecklistBody is declared below it, and biome's useExportsLast
// wants every export after the last non-export statement.
export { ChecklistWidget, DOC_URLS };

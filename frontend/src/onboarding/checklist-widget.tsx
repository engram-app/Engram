import { useQueryClient } from "@tanstack/react-query";
import { Waypoints } from "lucide-react";
import { useState } from "react";
import { Link } from "react-router";
import { type OnboardingStatus, useConnections, useOnboardingStatus } from "../api/queries";
import { useIsFreeTier } from "../billing/use-is-free-tier";
import { Button } from "../components/ui/button";
import { Shimmer } from "../components/ui/shimmer";
import { useOnboardingActions } from "./use-onboarding-actions";

interface Props {
	onStartTour: () => void;
}

interface Item {
	key: string;
	label: string;
	// `done` = genuinely completed (vault created, MCP/obsidian connection
	// resolved). Completed rows stay visible, struck through. Dismissal is a
	// separate user action (`dismissed`) that removes the row entirely.
	done: boolean;
	dismissed?: boolean;
	docUrl?: string;
	startTour?: () => void;
	dismissible?: boolean;
}

const DOC_URLS: Record<string, string> = {
	install_obsidian_plugin: "https://engram.page/docs/obsidian/install/",
	claude: "https://engram.page/docs/integrations/claude-desktop/",
	cursor: "https://engram.page/docs/integrations/cursor/",
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
	other_mcp: "https://engram.page/docs/mcp/manual-config/",
};
const DOC_FALLBACK = "https://engram.page/docs/integrations/";

const TOOL_LABELS: Record<string, string> = {
	claude: "Connect Claude Desktop",
	cursor: "Connect Cursor",
	claude_code: "Connect Claude Code",
	chatgpt: "Connect ChatGPT",
	grok: "Connect Grok",
	mistral: "Connect Mistral",
	open_webui: "Connect Open WebUI",
	lobechat: "Connect LobeChat",
	windsurf: "Connect Windsurf",
	cline: "Connect Cline",
	continue: "Connect Continue",
	opencode: "Connect OpenCode",
	github_copilot: "Connect GitHub Copilot",
	other_mcp: "Connect another MCP client",
};

export function ChecklistWidget({ onStartTour }: Props) {
	const [collapsed, setCollapsed] = useState(false);
	const ob = useOnboardingActions();
	const status = useOnboardingStatus();
	const profile = status.data?.profile;
	const connections = useConnections();
	const isFreeTier = useIsFreeTier();
	const qc = useQueryClient();

	if (ob.isLoading) {
		return null;
	}

	const isMobile = typeof window !== "undefined" && window.innerWidth < 768;
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

		void ob.recordAsync(action).catch(() => {
			// The mutation hook already retries 3× — reaching here means the
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

	const items: Item[] = [
		{
			key: "vault",
			label: "Create your first vault",
			done: ob.has("first_vault_created"),
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
					} as Item,
				]
			: []),
		...(isMobile || ob.has("tour_completed")
			? []
			: [
					{
						key: "tour",
						label: "Take the tour",
						// No in-row completion signal — `tour_completed` removes the row
						// structurally (guard above). Only dismissal hides it here.
						done: false,
						dismissed: isDismissed("tour"),
						startTour: onStartTour,
						dismissible: true,
					} as Item,
				]),
		...tools.map(
			(slug): Item => ({
				key: slug,
				label: TOOL_LABELS[slug] ?? `Connect ${slug}`,
				done: connectedSlugs.has(slug),
				dismissed: isDismissed(slug),
				docUrl: DOC_URLS[slug] ?? DOC_FALLBACK,
				dismissible: true,
			}),
		),
	];

	// Dismissed rows are removed entirely (the × is "hide this"). Completed rows
	// stay visible — struck through — so progress is felt, not silently erased.
	// The whole widget retires only once nothing is left to act on.
	const visible = items.filter((i) => !i.dismissed);
	const hasActionable = items.some((i) => !(i.done || i.dismissed));

	if (!hasActionable) {
		return null;
	}

	if (collapsed) {
		return (
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
		);
	}

	const total = items.length;
	const completed = items.filter((i) => i.done || i.dismissed).length;
	const pct = total === 0 ? 0 : Math.round((completed / total) * 100);

	return (
		<section
			aria-label="Onboarding checklist"
			className="fixed right-4 bottom-4 z-40 w-96 overflow-hidden rounded-xl border border-border bg-background shadow-xl ring-1 ring-primary/10"
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
			{total > 0 && (
				<div className="px-4 pt-3" aria-hidden>
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
			<ul className="flex flex-col gap-2 p-4">
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
						{/* Completed rows carry no actions — just the checked-off label. */}
						{!i.done && (
							<span className="flex items-center gap-1">
								{i.startTour ? (
									<Button size="sm" variant="outline" onClick={i.startTour}>
										Start
									</Button>
								) : i.docUrl ? (
									<Button asChild size="sm" variant="outline">
										<a href={i.docUrl} target="_blank" rel="noreferrer">
											Setup guide ↗
										</a>
									</Button>
								) : null}
								{Boolean(i.dismissible) && (
									<button
										type="button"
										aria-label={`Dismiss ${i.label}`}
										className="rounded-md p-1 text-muted-foreground hover:bg-muted hover:text-foreground"
										onClick={() => dismiss(i.key)}
									>
										×
									</button>
								)}
							</span>
						)}
					</li>
				))}
			</ul>
			{isFreeTier && (
				<p className="border-border border-t px-4 py-3 text-muted-foreground text-xs">
					You're on Free — 1 connection.{" "}
					<Link
						to="/onboard/billing"
						className="font-medium text-foreground underline underline-offset-4"
					>
						Upgrade
					</Link>
				</p>
			)}
		</section>
	);
}

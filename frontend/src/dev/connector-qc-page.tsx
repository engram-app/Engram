/**
 * Dev-only QC gallery for connector presentation. Mounted at `/__qc/connectors`
 * and only when `import.meta.env.DEV`, see router.tsx.
 *
 * Why this exists: the states worth reviewing (verified vendor / recognized
 * local / self-hosted / unrecognized, and every brand mark) each require a real
 * OAuth grant from a different vendor to reproduce. That is not a QC loop
 * anybody will run. Instead we seed the same react-query keys the real hooks
 * read and mount the REAL components, so this shows production code paths, not
 * a reimplementation that can drift away from them.
 *
 * Adding a connector? Add a fixture here and the row should render with its
 * brand mark and correct chip. If it doesn't, the catalog wiring is incomplete.
 */
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import type { ReactNode } from "react";
import type { BillingStatus, Connection, OnboardingStatus } from "../api/queries";
import type { EngramConfig } from "../config";
import { ConfigProvider } from "../config-context";
import { ChecklistWidget } from "../onboarding/checklist-widget";
import OnboardToolsPage from "../onboarding/onboard-tools-page";
import ConnectionsPage from "../settings/connections-page";

function conn(over: Partial<Connection>): Connection {
	return {
		kind: "mcp",
		client_id: `client-${over.slug ?? over.name ?? "x"}`,
		key_id: null,
		name: "Client",
		software_id: null,
		software_version: null,
		verified: false,
		logo: null,
		slug: null,
		vault_id: null,
		vault_name: "Engram",
		scope: "mcp",
		last_used_at: null,
		connected_at: "2026-07-30T15:00:00Z",
		first_user_agent: null,
		first_ip: "::ffff:10.30.1.140",
		redirect_uris: [],
		cimd_url: null,
		...over,
	} as Connection;
}

// Every row below is a real registration observed in prod on 2026-07-30, except
// the two marked otherwise. Keep them real: invented fixtures drift from what
// clients actually send, which is the bug class this whole page guards.
const CONNECTIONS: Connection[] = [
	conn({
		name: "Claude",
		slug: "claude",
		verified: true,
		logo: "/assets/clients/claude.svg",
		redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
	}),
	conn({
		name: "ChatGPT",
		slug: "chatgpt",
		verified: true,
		redirect_uris: ["https://chatgpt.com/connector/oauth/ig2N09X8ZQ6D"],
		first_user_agent: "Python/3.12 aiohttp/3.13.5",
	}),
	conn({
		name: "Grok",
		slug: "grok",
		verified: true,
		redirect_uris: ["https://grok.com/connectors-oauth-exchange-code/"],
		first_user_agent: "Grok",
	}),
	conn({
		name: "Mistral",
		slug: "mistral",
		verified: true,
		redirect_uris: ["https://callback.mistral.ai/v1/integrations_auth/oauth2_callback"],
		first_user_agent: "MistralAI-MCPClient/1.0",
	}),
	conn({
		name: "Antigravity",
		slug: "antigravity",
		verified: true,
		redirect_uris: ["https://antigravity.google/oauth-callback"],
		first_user_agent: "Go-http-client/2.0",
	}),
	conn({
		name: "Claude Code (engram)",
		slug: "claude_code",
		verified: false,
		redirect_uris: ["http://localhost:62184/callback"],
		first_user_agent: "Bun/1.4.0",
	}),
	conn({
		name: "Open WebUI",
		slug: "open_webui",
		verified: false,
		redirect_uris: ["https://ai.ras.band/oauth/clients/mcp:1/callback"],
		first_user_agent: "Python/3.11 aiohttp/3.13.5",
	}),
	// Not observed yet: the CIMD shape. Same loopback redirect as the Claude Code
	// row above, but verified — the metadata document is the proof the redirect
	// cannot supply. Worth eyeballing side by side, since the two rows differ only
	// in whether a document exists.
	conn({
		name: "Claude Code (engram)",
		slug: "claude_code",
		verified: true,
		redirect_uris: ["http://localhost:62184/callback"],
		cimd_url: "https://claude.ai/.well-known/oauth-client",
		first_user_agent: "Bun/1.4.0",
	}),
	// Not observed: a CIMD vendor with no allowlist entry. Verified on the strength
	// of the document alone, displaying the host it was served from.
	conn({
		name: "newvendor-client",
		slug: null,
		verified: true,
		redirect_uris: ["http://127.0.0.1:5000/cb"],
		cimd_url: "https://newvendor.example/mcp-client",
	}),
	// Not observed, the unrecognized case, which must still look actionable.
	conn({
		name: "some-random-agent",
		slug: null,
		verified: false,
		redirect_uris: ["http://localhost:9999/cb"],
	}),
	// Not observed, device-flow Obsidian, verified via our own minted family_id.
	conn({
		kind: "obsidian",
		name: "Obsidian Vault Sync",
		slug: null,
		verified: true,
		software_id: "engram-vault-sync",
		logo: "/assets/clients/engram-vault-sync.svg",
	}),
];

const TOOLS = [
	"claude",
	"chatgpt",
	"grok",
	"mistral",
	"open_webui",
	"claude_code",
	"antigravity",
	"cursor",
	"other_mcp",
];

const CONFIG = { billingEnabled: true } as EngramConfig;

function status(over: Partial<OnboardingStatus> = {}): OnboardingStatus {
	return {
		enabled: true,
		next_step: "done",
		steps: [],
		actions: ["first_vault_created"],
		vault_count: 1,
		profile: { uses_obsidian: false, tools: TOOLS },
		...over,
	} as OnboardingStatus;
}

/** Each panel gets its own client so one panel's cache can't leak into another. */
function Panel({
	title,
	note,
	connections,
	onboarding,
	children,
}: {
	title: string;
	note: string;
	connections?: Connection[];
	onboarding?: OnboardingStatus;
	children: ReactNode;
}) {
	const qc = new QueryClient({
		defaultOptions: { queries: { retry: false, staleTime: Number.POSITIVE_INFINITY } },
	});
	qc.setQueryData(["connections"], connections ?? []);
	qc.setQueryData(["onboarding", "status"], onboarding ?? status());
	qc.setQueryData(["billing", "status"], { tier: "pro", active: true } as BillingStatus);

	return (
		<section className="flex flex-col gap-3 border-border border-t pt-8">
			<header className="flex flex-col gap-1">
				<h2 className="font-semibold text-xl tracking-tight">{title}</h2>
				<p className="text-muted-foreground text-sm">{note}</p>
			</header>
			<ConfigProvider config={CONFIG}>
				<QueryClientProvider client={qc}>{children}</QueryClientProvider>
			</ConfigProvider>
		</section>
	);
}

export default function ConnectorQcPage() {
	return (
		<main className="mx-auto flex max-w-5xl flex-col gap-10 p-8">
			<header className="flex flex-col gap-2">
				<h1 className="font-bold text-3xl tracking-tight">Connector QC</h1>
				<p className="text-muted-foreground">
					Dev-only. Real components, seeded fixtures. Mutations (Revoke, dismiss) will fire real
					requests. Look, don't click.
				</p>
			</header>

			<Panel
				title="Connections page"
				note="Top five are verified by vendor host (no chip). Claude Code + Open WebUI are recognized but unprovable. No chip either, provenance in the expanded row. Only the unrecognized client is chipped. Expand a row to read the Identity line."
				connections={CONNECTIONS}
			>
				<ConnectionsPage />
			</Panel>

			<Panel
				title="Finish-setup checklist"
				note="Tools picked in FTUX vs live connections. claude/chatgpt/grok/mistral/open_webui/claude_code/antigravity should be struck through; cursor should still be actionable; 'another MCP client' ticks off the unrecognized grant."
				connections={CONNECTIONS}
			>
				<ChecklistWidget
					onStartTour={() => {
						// The product tour is out of scope for connector QC.
					}}
				/>
			</Panel>

			<Panel
				title="FTUX tool picker"
				note="Gemini is listed, greyed, dashed and unselectable with its reason. Antigravity is selectable under Coding tools. Every option should show a brand mark."
				onboarding={status({ next_step: "tools" })}
			>
				<OnboardToolsPage />
			</Panel>
		</main>
	);
}

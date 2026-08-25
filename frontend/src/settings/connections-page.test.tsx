import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { describe, expect, it, vi } from "vitest";
import ConnectionsPage from "./connections-page";

// Records the router's current hash so a test can prove a click actually
// navigated (via history.push), not merely that the link's href looked right.
function LocationProbe() {
	const loc = useLocation();
	return <output data-testid="loc-hash">{loc.hash}</output>;
}

// ── Controllable mock state ───────────────────────────────────
// vi.mock is hoisted; we use these module-level variables to vary
// the data returned per test without re-importing.

const mockConnections: import("../api/queries").Connection[] = [];
let mockTier = "starter";
const mockRevokeDevice = vi.fn().mockResolvedValue(undefined);
const mockRevokeOauth = vi.fn().mockResolvedValue(undefined);
const mockRevokePat = vi.fn().mockResolvedValue(undefined);

vi.mock("../api/queries", async () => {
	const actual = await vi.importActual<typeof import("../api/queries")>("../api/queries");
	return {
		...actual,
		useConnections: () => ({
			data: mockConnections,
			isLoading: false,
			error: null,
		}),
		// Mirror the real payload: the page reads `caps`, not the tier string.
		// API keys are Pro-only, so only Pro resolves api_write_enabled true.
		useBillingStatus: () => ({
			data: {
				tier: mockTier,
				caps: {
					api_write_enabled: mockTier === "pro",
					obsidian_connections: mockTier === "free" ? 2 : null,
					mcp_connections: mockTier === "free" ? 1 : null,
					vaults: mockTier === "free" ? 1 : null,
				},
			},
		}),
		useRevokeOauthConnection: () => ({ mutate: vi.fn(), mutateAsync: mockRevokeOauth }),
		useRevokeDeviceConnection: () => ({ mutate: vi.fn(), mutateAsync: mockRevokeDevice }),
		useRevokePat: () => ({ mutate: vi.fn(), mutateAsync: mockRevokePat }),
		useCreatePat: () => ({
			mutate: vi.fn(),
			mutateAsync: vi.fn(),
			isPending: false,
			error: null,
		}),
	};
});

vi.mock("../config-context", async () => {
	const actual = await vi.importActual<typeof import("../config-context")>("../config-context");
	return {
		...actual,
		// SaaS context, free-tier cap fallbacks under test depend on this.
		useConfig: () => ({ billingEnabled: true }) as ReturnType<typeof actual.useConfig>,
	};
});

// ── Fixture data ──────────────────────────────────────────────

const baseObs: import("../api/queries").Connection = {
	kind: "obsidian",
	client_id: "family-1",
	key_id: null,
	name: "Obsidian Vault Sync",
	software_id: "engram-vault-sync",
	software_version: null,
	verified: true,
	logo: "/x.svg",
	slug: null,
	vault_id: "1",
	vault_name: null,
	scope: null,
	last_used_at: null,
	connected_at: "2026-05-30T00:00:00Z",
	first_user_agent: null,
	first_ip: null,
	redirect_uri: null,
	redirect_uris: [],
	cimd_url: null,
};

const basePat: import("../api/queries").Connection = {
	kind: "pat",
	client_id: null,
	key_id: "7",
	name: "ci-bot",
	software_id: null,
	software_version: null,
	verified: false,
	logo: null,
	slug: null,
	vault_id: null,
	vault_name: null,
	scope: null,
	last_used_at: null,
	connected_at: "2026-05-30T00:00:00Z",
	first_user_agent: null,
	first_ip: null,
	redirect_uri: null,
	redirect_uris: [],
	cimd_url: null,
};

const baseMcp: import("../api/queries").Connection = {
	kind: "mcp",
	client_id: "client-abc",
	key_id: null,
	name: "Claude Desktop",
	software_id: "claude-desktop",
	software_version: "1.2.0",
	verified: false,
	logo: null,
	slug: null,
	vault_id: null,
	vault_name: null,
	scope: "notes:read notes:write",
	last_used_at: null,
	connected_at: "2026-05-30T00:00:00Z",
	first_user_agent: "Claude/1.2.0",
	first_ip: "1.2.3.4",
	redirect_uri: null,
	redirect_uris: ["http://localhost:3000/callback"],
	cimd_url: null,
};

// ── Render helper ─────────────────────────────────────────────

function renderPage() {
	const qc = new QueryClient();
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter>
				<LocationProbe />
				<ConnectionsPage />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

// ── Tests ─────────────────────────────────────────────────────

describe("ConnectionsPage", () => {
	it("renders the three section headings", () => {
		mockConnections.splice(0, mockConnections.length, baseObs, basePat);
		mockTier = "starter";
		renderPage();
		expect(screen.getByRole("heading", { name: /Obsidian plugins/iu })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /AI tools/iu })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /API keys/iu })).toBeInTheDocument();
	});

	// A recognized local/self-hosted client is unverifiable by construction, so
	// it must not carry the same "unverified" badge as an unknown client, that
	// reads as a fixable fault and prompts "am I connected wrong?".
	it("shows no warning chip for a recognized client, explaining provenance in the detail row", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			slug: "claude_code",
			verified: false,
		});
		mockTier = "starter";
		renderPage();

		expect(screen.queryByText(/^unverified$/iu)).toBeNull();
		expect(screen.getByText(/self-reported/iu)).toBeInTheDocument();
	});

	// Claude Code registers as "Claude Code (<mcp-server-name>)" where the suffix
	// is whatever the user named their server, so passing the raw client_name
	// through puts a local config detail in a list of vendor names. Once the slug
	// resolves we know the product, so show the catalog spelling.
	it("shows the catalog product name, not the client's self-reported one", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			name: "Claude Code (engram)",
			slug: "claude_code",
			verified: false,
		});
		mockTier = "starter";
		renderPage();

		// getAllBy: the brand mark's <title> carries the product name too.
		expect(screen.getAllByText("Claude Code").length).toBeGreaterThan(0);
		expect(screen.queryByText(/\(engram\)/u)).toBeNull();
	});

	// No slug means no catalog entry to prefer, so the self-reported name is all
	// we have and must still render rather than collapsing to "Unnamed".
	it("keeps the self-reported name when no slug resolved", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			name: "Some Unknown Client",
			slug: null,
			verified: false,
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText("Some Unknown Client")).toBeInTheDocument();
	});

	// CIMD is the whole point of #1148: a loopback client CAN be verified, because
	// the proof is a document at a domain the vendor owns rather than where the
	// sign-in code lands. The copy must say that, not the redirect story — Claude
	// Code redirects to localhost, so "redirects to a domain the vendor owns"
	// would be plainly false.
	it("explains a CIMD client's identity by its published document, not its redirect", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			slug: "claude_code",
			verified: true,
			cimd_url: "https://claude.ai/.well-known/oauth-client",
			redirect_uri: null,
			redirect_uris: ["http://localhost:62184/callback"],
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText(/publishes its identity at a domain it owns/iu)).toBeInTheDocument();
		expect(screen.queryByText(/sign-in redirects to a domain/iu)).toBeNull();
		expect(screen.queryByText(/^unverified$/iu)).toBeNull();
		expect(screen.queryByText(/self-reported/iu)).toBeNull();
	});

	// `verified` is the ONLY gate on claiming verification; cimd_url merely picks
	// which proof to name. Branching on cimd_url alone would restate the backend's
	// verification rule in TypeScript with nothing keeping them in sync, so a
	// loosened SsrfGuard could have the UI assert a proof the server never granted.
	// This state should be unreachable today — that is exactly why it is pinned.
	it("never claims verification from cimd_url alone when the server says unverified", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			slug: "claude_code",
			verified: false,
			cimd_url: "https://claude.ai/.well-known/oauth-client",
		});
		mockTier = "starter";
		renderPage();

		expect(screen.queryByText(/^verified\./iu)).toBeNull();
		expect(screen.queryByText(/publishes its identity/iu)).toBeNull();
		expect(screen.getByText(/self-reported/iu)).toBeInTheDocument();
	});

	// A redirect-verified client keeps the redirect wording. If both branches ever
	// collapse to one string, one of the two will be a lie.
	it("keeps the redirect wording for a client verified by its redirect host", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			slug: "claude",
			verified: true,
			cimd_url: null,
			redirect_uri: null,
			redirect_uris: ["https://claude.ai/api/mcp/auth_callback"],
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText(/sign-in redirects to a domain the vendor owns/iu)).toBeInTheDocument();
	});

	// The URL is the client's public identifier and, unlike an opaque UUID, the
	// user can check it by visiting it.
	it("shows the CIMD URL as the identifier instead of the internal uuid", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			client_id: "3f2b9c14-0000-4000-8000-000000000000",
			verified: true,
			cimd_url: "https://claude.ai/.well-known/oauth-client",
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText("https://claude.ai/.well-known/oauth-client")).toBeInTheDocument();
		expect(screen.queryByText("3f2b9c14-0000-4000-8000-000000000000")).toBeNull();
	});

	it("still labels an unrecognized client unverified", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			slug: null,
			verified: false,
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText(/^unverified$/iu)).toBeInTheDocument();
		expect(screen.queryByText(/^self-reported$/iu)).toBeNull();
	});

	// Brand marks come from the slug, not a per-vendor asset the backend has to
	// ship, Grok has no /assets/clients/grok.svg and still renders its mark.
	it("renders the brand mark for a slugged connection with no logo asset", () => {
		mockConnections.splice(0, mockConnections.length, { ...baseMcp, slug: "grok", logo: null });
		mockTier = "starter";
		renderPage();
		expect(screen.getByTestId("tool-mark-grok")).toBeInTheDocument();
	});

	it("falls back to the backend logo, then a plug, when the slug has no mark", () => {
		mockConnections.splice(0, mockConnections.length, baseObs);
		mockTier = "starter";
		const { container } = renderPage();
		expect(container.querySelector('img[src="/x.svg"]')).toBeInTheDocument();
		expect(screen.queryByTestId(/^tool-mark-/u)).toBeNull();
	});

	it("shows the obsidian connection name and omits the unverified badge", () => {
		mockConnections.splice(0, mockConnections.length, baseObs, basePat);
		mockTier = "starter";
		renderPage();
		expect(screen.getByText(/Obsidian Vault Sync/iu)).toBeInTheDocument();
		expect(screen.queryByText(/unverified/iu)).not.toBeInTheDocument();
	});

	it("shows the PAT in the api-keys section", () => {
		mockConnections.splice(0, mockConnections.length, baseObs, basePat);
		mockTier = "starter";
		renderPage();
		expect(screen.getByText(/ci-bot/iu)).toBeInTheDocument();
	});

	it("shows MCP empty state when no mcp connections", () => {
		mockConnections.splice(0, mockConnections.length, baseObs, basePat);
		mockTier = "starter";
		renderPage();
		expect(
			screen.getByText(/Connect Claude Desktop, Cursor, or another MCP client/iu),
		).toBeInTheDocument();
	});

	it("shows create button when tier is pro", () => {
		mockConnections.splice(0, mockConnections.length, baseObs, basePat);
		mockTier = "pro";
		renderPage();
		expect(screen.getByRole("button", { name: /\+ New Key/iu })).toBeInTheDocument();
	});

	it("shows upgrade CTA when tier is free", () => {
		mockConnections.splice(0, mockConnections.length, basePat);
		mockTier = "free";
		renderPage();
		expect(screen.getByText(/Upgrade to Pro to create API keys/iu)).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: /\+ New Key/iu })).not.toBeInTheDocument();
	});

	// API keys moved to Pro-only. Starter is a PAID tier that still must not
	// see the create affordance — the old gate keyed on "not free" and would
	// have offered Starter a button the server refuses with 402.
	it("shows upgrade CTA when tier is starter", () => {
		mockConnections.splice(0, mockConnections.length, basePat);
		mockTier = "starter";
		renderPage();
		expect(screen.getByText(/Upgrade to Pro to create API keys/iu)).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: /\+ New Key/iu })).not.toBeInTheDocument();
	});

	it("Upgrade CTA click actually navigates (not just a correct href)", () => {
		mockConnections.splice(0, mockConnections.length, basePat);
		mockTier = "free";
		renderPage();
		expect(screen.getByTestId("loc-hash")).toHaveTextContent("");
		fireEvent.click(screen.getByRole("link", { name: /upgrade/iu }));
		expect(screen.getByTestId("loc-hash")).toHaveTextContent("#settings/billing");
	});

	it("shows unverified badge for MCP connection with verified=false", () => {
		mockConnections.splice(0, mockConnections.length, baseMcp);
		mockTier = "starter";
		renderPage();
		// "Claude Desktop" also appears in the header docs blurb, so scope to
		// the AI-tools section.
		const section = screen.getByRole("region", { name: /AI tools/iu });
		expect(within(section).getByText(/unverified/iu)).toBeInTheDocument();
		expect(within(section).getByText(/Claude Desktop/iu)).toBeInTheDocument();
	});

	it('uses singular "Vault:" for obsidian and plural "Vaults:" for mcp cards', () => {
		// PATs are rendered in a separate table without a Vault label, so this
		// exercises only the card-layout obsidian + mcp rows.
		mockConnections.splice(
			0,
			mockConnections.length,
			{ ...baseObs, vault_name: "Personal" },
			baseMcp,
		);
		mockTier = "starter";
		renderPage();
		expect(screen.getByText("Vault:")).toBeInTheDocument();
		expect(screen.getByText(/Personal/u)).toBeInTheDocument();
		// MCP card: plural + "All vaults" since baseMcp.vault_id is null
		expect(screen.getByText("Vaults:")).toBeInTheDocument();
		expect(screen.getByText(/All vaults/u)).toBeInTheDocument();
	});

	it("falls back to #<id> when vault_name is missing", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseObs,
			vault_id: "42",
			vault_name: null,
		});
		mockTier = "starter";
		renderPage();
		expect(screen.getByText(/#42/u)).toBeInTheDocument();
	});

	it("opens the revoke modal and calls mutateAsync on confirm", async () => {
		mockRevokeDevice.mockClear();
		mockConnections.splice(0, mockConnections.length, baseObs);
		mockTier = "starter";
		renderPage();
		// Click the revoke button in the obsidian card summary.
		fireEvent.click(screen.getAllByRole("button", { name: /^Revoke$/u })[0]!);
		// Modal renders with the connection name in the title.
		expect(screen.getByRole("dialog")).toBeInTheDocument();
		expect(screen.getByText(/Revoke "Obsidian Vault Sync"\?/u)).toBeInTheDocument();
		// Confirm button = the second one (first is the in-card trigger that
		// opened this modal, now hidden behind the dialog).
		const confirmButton = screen
			.getAllByRole("button", { name: /^Revoke$/u })
			.find((b) => b.closest('[role="dialog"]'))!;
		fireEvent.click(confirmButton);
		await waitFor(() => expect(mockRevokeDevice).toHaveBeenCalledWith("family-1"));
		await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
	});

	it("keeps modal open and surfaces error message when revoke fails", async () => {
		mockRevokeOauth.mockClear();
		mockRevokeOauth.mockRejectedValueOnce(new Error("Boom"));
		mockConnections.splice(0, mockConnections.length, baseMcp);
		mockTier = "starter";
		renderPage();
		fireEvent.click(screen.getAllByRole("button", { name: /^Revoke$/u })[0]!);
		const confirmButton = screen
			.getAllByRole("button", { name: /^Revoke$/u })
			.find((b) => b.closest('[role="dialog"]'))!;
		fireEvent.click(confirmButton);
		await waitFor(() => expect(screen.getByText("Boom")).toBeInTheDocument());
		// Dialog still mounted so the user can retry or cancel.
		expect(screen.getByRole("dialog")).toBeInTheDocument();
	});

	it("cancel button closes the modal without invoking the mutation", () => {
		mockRevokePat.mockClear();
		mockConnections.splice(0, mockConnections.length, basePat);
		mockTier = "starter";
		renderPage();
		fireEvent.click(screen.getAllByRole("button", { name: /^Revoke$/u })[0]!);
		expect(screen.getByRole("dialog")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: /^Cancel$/u }));
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(mockRevokePat).not.toHaveBeenCalled();
	});
});

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createEvent, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
import { toast } from "sonner";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "@/api/client";
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
// Drops `caps` from the billing payload, the shape of a response that has not
// carried them (the page must not invent a limit to fill the gap).
let mockOmitCaps = false;
const mockRevokeDevice = vi.fn().mockResolvedValue(undefined);
const mockRevokeOauth = vi.fn().mockResolvedValue(undefined);
const mockRevokePat = vi.fn().mockResolvedValue(undefined);
const mockCreatePat = vi.fn().mockResolvedValue({ key: "engram_k", id: "9", name: "ci" });
const mockUpdateAccess = vi.fn();
// The backend's capability flag for per-vault access levels (#174, #332).
let mockLevelsSupported = true;
// Null is a loaded list; set it to drive a pending or failed vault query.
const mockVaultsQuery: { current: object | null } = { current: null };
const mockVaults = [
	{ id: "v1", name: "Personal", is_default: true, note_count: 1, attachment_count: 0 },
	{ id: "v2", name: "Work", is_default: false, note_count: 1, attachment_count: 0 },
];

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
		useBillingStatus: () => ({
			data: {
				tier: mockTier,
				caps: mockOmitCaps
					? undefined
					: {
							obsidian_connections: mockTier === "free" ? 2 : null,
							vaults: mockTier === "free" ? 1 : null,
						},
			},
		}),
		useRevokeOauthConnection: () => ({ mutate: vi.fn(), mutateAsync: mockRevokeOauth }),
		useRevokeDeviceConnection: () => ({ mutate: vi.fn(), mutateAsync: mockRevokeDevice }),
		useRevokePat: () => ({ mutate: vi.fn(), mutateAsync: mockRevokePat }),
		useCreatePat: () => ({
			mutate: vi.fn(),
			mutateAsync: mockCreatePat,
			isPending: false,
			error: null,
		}),
		useUpdateConnectionAccess: () => ({
			mutate: vi.fn(),
			mutateAsync: mockUpdateAccess,
			isPending: false,
		}),
		useVaults: () =>
			mockVaultsQuery.current ?? { data: mockVaults, isLoading: false, isSuccess: true },
		useAccessLevelsSupported: () => mockLevelsSupported,
	};
});

vi.mock("sonner", () => ({
	toast: { success: vi.fn(), error: vi.fn() },
}));

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
	family_id: "family-1",
	key_id: null,
	name: "Obsidian Vault Sync",
	label: null,
	software_id: "engram-vault-sync",
	software_version: null,
	verified: true,
	logo: "/x.svg",
	slug: null,
	vault_ids: ["1"],
	vault_names: [null],
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
	family_id: null,
	key_id: "7",
	name: "ci-bot",
	label: null,
	software_id: null,
	software_version: null,
	verified: false,
	logo: null,
	slug: null,
	vault_ids: null,
	vault_names: null,
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
	family_id: "grant-abc",
	key_id: null,
	name: "Claude Desktop",
	label: null,
	software_id: "claude-desktop",
	software_version: "1.2.0",
	verified: false,
	logo: null,
	slug: null,
	vault_ids: null,
	vault_names: null,
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

// Every connection card on the page, in order.
function cards(): HTMLElement[] {
	return screen
		.getAllByRole("button", { name: /^view details/iu })
		.map((b) => b.closest("article") as HTMLElement);
}

// Each access line of the only card, as read aloud: level, then vaults.
function accessLines(): string[] {
	const [card] = cards();
	return within(card as HTMLElement)
		.getAllByRole("listitem")
		.map((li) => li.textContent ?? "");
}

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
	beforeEach(() => {
		mockOmitCaps = false;
	});

	it("shows the served Free device cap next to the Obsidian count", () => {
		mockConnections.splice(0, mockConnections.length, baseObs);
		mockTier = "free";
		renderPage();
		expect(screen.getByRole("heading", { name: "Obsidian plugins (1 / 2)" })).toBeInTheDocument();
	});

	it("shows a bare count, not a guessed limit, when caps are absent", () => {
		mockConnections.splice(0, mockConnections.length, baseObs);
		mockTier = "free";
		mockOmitCaps = true;
		renderPage();
		expect(screen.getByRole("heading", { name: "Obsidian plugins (1)" })).toBeInTheDocument();
	});

	it("renders the three section headings", () => {
		mockConnections.splice(0, mockConnections.length, baseObs, basePat);
		mockTier = "starter";
		renderPage();
		expect(screen.getByRole("heading", { name: /Obsidian plugins/iu })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /AI tools/iu })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: /API keys/iu })).toBeInTheDocument();
	});

	// A slug derived from the self-reported client_name is a claim, not a proof:
	// anyone can register as "ChatGPT" from localhost. Only `verified` earns a
	// vendor mark and drops the chip; provenance stays in the detail row.
	it("shows no vendor mark and keeps the chip for an unverified client claiming a vendor name", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			name: "ChatGPT",
			slug: "chatgpt",
			verified: false,
			redirect_uri: "http://localhost:9999/cb",
		});
		mockTier = "starter";
		renderPage();

		expect(screen.queryByTestId("tool-mark-chatgpt")).toBeNull();
		expect(screen.getByText(/^unverified$/iu)).toBeInTheDocument();
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

	describe("search", () => {
		// Nine keys: one over SEARCH_THRESHOLD, so the toggle appears.
		function manyPats() {
			return Array.from({ length: 9 }, (_, i) => ({
				...basePat,
				key_id: `k${i}`,
				name: i === 0 ? "ci-bot" : `script-${i}`,
			}));
		}

		it("offers nothing while every connection is already on screen", () => {
			mockConnections.splice(0, mockConnections.length, { ...basePat, name: "ci-bot" });
			mockTier = "starter";
			renderPage();

			expect(screen.queryByRole("button", { name: /Search connections/iu })).toBeNull();
			expect(screen.queryByRole("searchbox")).toBeNull();
		});

		it("keeps the field behind a toggle once there is enough to search", () => {
			mockConnections.splice(0, mockConnections.length, ...manyPats());
			mockTier = "starter";
			renderPage();

			expect(screen.queryByRole("searchbox")).toBeNull();
			fireEvent.click(screen.getByRole("button", { name: /Search connections/iu }));
			expect(screen.getByRole("searchbox", { name: /Search connections/iu })).toBeInTheDocument();
		});

		it("filters rows without rewriting the counts", () => {
			mockConnections.splice(0, mockConnections.length, ...manyPats());
			mockTier = "starter";
			renderPage();

			fireEvent.click(screen.getByRole("button", { name: /Search connections/iu }));
			fireEvent.change(screen.getByRole("searchbox", { name: /Search connections/iu }), {
				target: { value: "ci-bot" },
			});

			expect(screen.getByText("ci-bot")).toBeInTheDocument();
			expect(screen.queryByText("script-3")).toBeNull();
			// The heading counts what the user HAS. A section header that moved
			// with the filter would read as though keys had been deleted — and on
			// the capped sections, as though a plan slot had freed up.
			expect(screen.getByRole("heading", { name: /API keys \(9\)/iu })).toBeInTheDocument();
		});

		it("does not tell you to install a plugin when a filter emptied the section", () => {
			mockConnections.splice(0, mockConnections.length, ...manyPats());
			mockTier = "starter";
			renderPage();

			fireEvent.click(screen.getByRole("button", { name: /Search connections/iu }));
			fireEvent.change(screen.getByRole("searchbox", { name: /Search connections/iu }), {
				target: { value: "ci-bot" },
			});

			expect(screen.queryByText(/Install the Engram Vault Sync plugin/iu)).toBeNull();
			expect(screen.getAllByText("No matches.").length).toBeGreaterThan(0);
		});
	});

	// The catalog spelling beats the client's self-reported name, but it must
	// NOT beat the user's own. Two grants for the same client both resolve to
	// the same slug, so preferring the catalog there collapses them into two
	// rows reading "Claude Code" — erasing the one string that told them apart.
	it("shows the user's label over the catalog product name", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			label: "Work laptop",
			name: "Work laptop",
			slug: "claude_code",
			verified: false,
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText("Work laptop")).toBeInTheDocument();
	});

	it("shows a restricted API key's vaults, not All vaults", () => {
		mockConnections.splice(0, mockConnections.length, {
			...basePat,
			name: "ci-bot",
			vault_ids: ["v1", "v2"],
			vault_names: ["Personal", "Research"],
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText("Personal, Research")).toBeInTheDocument();
		expect(screen.queryByText("All vaults")).toBeNull();
	});

	// A key restricted to a vault that has been soft-deleted still carries the
	// id; the name comes back null. Dropping the entry would render the row
	// empty, which reads as unrestricted — the exact opposite of the truth.
	it("names a deleted vault rather than printing its id", () => {
		mockConnections.splice(0, mockConnections.length, {
			...basePat,
			name: "ci-bot",
			vault_ids: ["v1", "v2"],
			vault_names: ["Personal", null],
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText("Personal, (deleted vault)")).toBeInTheDocument();
		expect(screen.queryByText(/#v2/u)).toBeNull();
	});

	it("still shows a restriction when its only vault is gone", () => {
		mockConnections.splice(0, mockConnections.length, {
			...basePat,
			name: "ci-bot",
			vault_ids: ["v1"],
			vault_names: [null],
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText("(deleted vault)")).toBeInTheDocument();
		expect(screen.queryByText("All vaults")).toBeNull();
	});

	it("says All vaults for an unrestricted API key", () => {
		mockConnections.splice(0, mockConnections.length, {
			...basePat,
			name: "ci-bot",
			vault_ids: null,
			vault_names: null,
		});
		mockTier = "starter";
		renderPage();

		expect(screen.getByText("All vaults")).toBeInTheDocument();
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
		mockConnections.splice(0, mockConnections.length, {
			...baseMcp,
			slug: "grok",
			logo: null,
			verified: true,
		});
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

	it("hides a card's details until View details is pressed, one card at a time", () => {
		mockConnections.splice(0, mockConnections.length, baseMcp, basePat);
		mockTier = "starter";
		renderPage();
		const [mcpCard, keyCard] = cards() as [HTMLElement, HTMLElement];
		const toggle = within(keyCard).getByRole("button", { name: /^view details ci-bot$/iu });
		const details = document.getElementById(toggle.getAttribute("aria-controls") ?? "");
		expect(details).toBe(keyCard.querySelector("dl"));
		expect(toggle).toHaveAttribute("aria-expanded", "false");
		expect(details).not.toBeVisible();
		fireEvent.click(toggle);
		expect(toggle).toHaveAttribute("aria-expanded", "true");
		expect(toggle).toHaveAccessibleName(/^hide details ci-bot$/iu);
		expect(details).toBeVisible();
		expect(mcpCard.querySelector("dl")).not.toBeVisible();
		fireEvent.click(toggle);
		expect(details).not.toBeVisible();
	});

	it("names each card's buttons after the card", () => {
		mockConnections.splice(0, mockConnections.length, baseMcp, basePat);
		mockTier = "starter";
		renderPage();
		expect(screen.getByRole("button", { name: /^revoke ci-bot$/iu })).toBeInTheDocument();
		expect(screen.getAllByRole("button", { name: /^revoke /iu })).toHaveLength(2);
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

	// #1974: API keys work on every route on every tier, so every tier can
	// create one and no plan is told to upgrade for API access.
	it.each(["free", "starter", "pro"])("lets %s create a key with no API upsell", (tier) => {
		mockConnections.splice(0, mockConnections.length, basePat);
		mockTier = tier;
		renderPage();
		expect(screen.getByRole("button", { name: /\+ New Key/iu })).toBeInTheDocument();
		expect(screen.queryByText(/REST API/iu)).not.toBeInTheDocument();
		expect(screen.queryByText(/Upgrade to Pro/iu)).not.toBeInTheDocument();
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

	it('names the obsidian vault and says "All vaults" for an unrestricted legacy grant', () => {
		mockConnections.splice(
			0,
			mockConnections.length,
			{ ...baseObs, vault_names: ["Personal"] },
			baseMcp,
		);
		mockTier = "starter";
		renderPage();
		const [obsidian, mcp] = cards();
		expect(within(obsidian as HTMLElement).getByText("Personal")).toBeInTheDocument();
		// baseMcp.vault_ids is null: a pre-levels grant over every vault.
		expect(within(mcp as HTMLElement).getByText("All vaults")).toBeInTheDocument();
	});

	// Used to print the raw id. A vault id is an opaque UUID that means nothing
	// to the person reading it; what they need to know is that the vault is
	// gone, and that the connection is still restricted to it.
	it("names a missing vault instead of printing its id", () => {
		mockConnections.splice(0, mockConnections.length, {
			...baseObs,
			vault_ids: ["42"],
			vault_names: [null],
		});
		mockTier = "starter";
		renderPage();
		expect(screen.getByText(/\(deleted vault\)/u)).toBeInTheDocument();
		expect(screen.queryByText(/#42/u)).toBeNull();
	});

	it("opens the revoke modal and calls mutateAsync on confirm", async () => {
		mockRevokeDevice.mockClear();
		mockConnections.splice(0, mockConnections.length, baseObs);
		mockTier = "starter";
		renderPage();
		// Click the revoke button in the obsidian card summary.
		fireEvent.click(screen.getAllByRole("button", { name: /^Revoke /u })[0]!);
		// Modal renders with the connection name in the title.
		expect(screen.getByRole("dialog")).toBeInTheDocument();
		expect(screen.getByText(/Revoke "Obsidian Vault Sync"\?/u)).toBeInTheDocument();
		const confirmButton = within(screen.getByRole("dialog")).getByRole("button", {
			name: "Revoke access",
		});
		fireEvent.click(confirmButton);
		await waitFor(() => expect(mockRevokeDevice).toHaveBeenCalledWith("family-1"));
		await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument());
	});

	it("revokes only the grant whose Revoke was clicked, not the whole client", async () => {
		// Two grants of ONE client — the exact case labels exist to
		// disambiguate. Revoking "work" must not take "laptop" with it.
		mockRevokeOauth.mockClear();
		mockConnections.splice(
			0,
			mockConnections.length,
			{ ...baseMcp, name: "laptop", family_id: "grant-laptop" },
			{ ...baseMcp, name: "work", family_id: "grant-work" },
		);
		mockTier = "starter";
		renderPage();

		const workCard = screen.getByText("work").closest("li")!;
		fireEvent.click(within(workCard).getByRole("button", { name: /^Revoke /u }));
		const confirmButton = within(screen.getByRole("dialog")).getByRole("button", {
			name: "Revoke access",
		});
		fireEvent.click(confirmButton);

		await waitFor(() =>
			expect(mockRevokeOauth).toHaveBeenCalledWith({
				clientId: "client-abc",
				familyId: "grant-work",
			}),
		);
	});

	it("keeps modal open and surfaces error message when revoke fails", async () => {
		mockRevokeOauth.mockClear();
		mockRevokeOauth.mockRejectedValueOnce(new Error("Boom"));
		mockConnections.splice(0, mockConnections.length, baseMcp);
		mockTier = "starter";
		renderPage();
		fireEvent.click(screen.getAllByRole("button", { name: /^Revoke /u })[0]!);
		const confirmButton = within(screen.getByRole("dialog")).getByRole("button", {
			name: "Revoke access",
		});
		fireEvent.click(confirmButton);
		// The thrown text is not shown (server text is English in every locale).
		await waitFor(() => expect(screen.getByText("Revoke failed")).toBeInTheDocument());
		expect(screen.queryByText("Boom")).toBeNull();
		// Dialog still mounted so the user can retry or cancel.
		expect(screen.getByRole("dialog")).toBeInTheDocument();
	});

	it("cancel button closes the modal without invoking the mutation", () => {
		mockRevokePat.mockClear();
		mockConnections.splice(0, mockConnections.length, basePat);
		mockTier = "starter";
		renderPage();
		fireEvent.click(screen.getAllByRole("button", { name: /^Revoke /u })[0]!);
		expect(screen.getByRole("dialog")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: /^Cancel$/u }));
		expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
		expect(mockRevokePat).not.toHaveBeenCalled();
	});

	// #174 / #332: what each connection may do per vault, and to vaults
	// created later.
	describe("access levels", () => {
		function patWith(
			levels: { vault_id: string; vault_name: string; level: "none" | "read" | "write" }[],
			later: "none" | "read" | "write",
		) {
			mockConnections.splice(0, mockConnections.length, {
				...basePat,
				vault_ids: levels.map((l) => l.vault_id),
				vault_names: levels.map((l) => l.vault_name),
				vault_levels: levels,
				new_vaults: later,
			});
			mockTier = "starter";
			renderPage();
		}

		it("marks read-only vaults", () => {
			patWith(
				[
					{ vault_id: "v1", vault_name: "Personal", level: "write" },
					{ vault_id: "v2", vault_name: "Work", level: "read" },
				],
				"none",
			);
			expect(accessLines()).toEqual(["Can read and change notes Personal", "Can read notes Work"]);
		});

		it("names the policy for vaults created later", () => {
			patWith([{ vault_id: "v1", vault_name: "Personal", level: "write" }], "read");
			expect(accessLines()).toEqual([
				"Can read and change notes Personal",
				"Can read notes Vaults you create later",
			]);
		});

		it("never says All vaults while any vault is none", () => {
			patWith(
				[
					{ vault_id: "v1", vault_name: "Personal", level: "write" },
					{ vault_id: "v2", vault_name: "Work", level: "none" },
				],
				"write",
			);
			expect(screen.queryByText(/all vaults/iu)).toBeNull();
			expect(accessLines()).toEqual([
				"Can read and change notes Personal, Vaults you create later",
			]);
		});

		it("collapses one level everywhere to All vaults", () => {
			patWith(
				[
					{ vault_id: "v1", vault_name: "Personal", level: "read" },
					{ vault_id: "v2", vault_name: "Work", level: "read" },
				],
				"read",
			);
			expect(accessLines()).toEqual(["Can read notes All vaults, including ones you create later"]);
		});
		it("folds a long vault list into +N more", () => {
			patWith(
				["A", "B", "C", "D", "E"].map((n) => ({
					vault_id: n,
					vault_name: n,
					level: "read" as const,
				})),
				"none",
			);
			expect(accessLines()).toEqual(["Can read notes A, B, C +2 more"]);
		});

		it("says No access when nothing is reached", () => {
			patWith([{ vault_id: "v1", vault_name: "Personal", level: "none" }], "none");
			expect(cards()[0]).toHaveTextContent("No access");
		});

		function openNewKey(levelsSupported = true) {
			mockConnections.splice(0, mockConnections.length);
			mockTier = "pro";
			mockLevelsSupported = levelsSupported;
			mockCreatePat.mockClear();
			mockRevokePat.mockClear();
			// A backend with levels echoes what it stored: here, what was asked.
			mockCreatePat.mockImplementation(
				async (p: { name: string; vault_access?: object; default_access?: string }) => ({
					key: "engram_k",
					id: "9",
					name: p.name,
					vault_access: p.vault_access ?? {},
					default_access: p.default_access ?? (p.vault_access ? "none" : "write"),
				}),
			);
			renderPage();
			fireEvent.click(screen.getByRole("button", { name: /\+ New Key/iu }));
			fireEvent.change(screen.getByPlaceholderText(/ci-bot/iu), { target: { value: "ci" } });
		}

		function box(column: "read" | "write", vault: string): HTMLInputElement | null {
			return screen.queryByRole("checkbox", {
				name: new RegExp(`^${column}: ${vault}$`, "iu"),
			}) as HTMLInputElement | null;
		}

		function choose() {
			fireEvent.click(screen.getByRole("radio", { name: /^choose vaults$/iu }));
		}

		// Creating a key is two steps, like consent: Review, then Generate Key.
		function generate() {
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			fireEvent.click(screen.getByRole("button", { name: /generate key/iu }));
		}

		// "All vaults" is one table row with the same Read and Write boxes.
		const ALL = "all vaults, including ones you create later";

		function allReadOnly() {
			fireEvent.click(box("write", ALL) as HTMLInputElement);
		}

		it("a new key defaults to every vault with write access", async () => {
			openNewKey();
			expect(box("read", ALL)).toBeChecked();
			expect(box("write", ALL)).toBeChecked();
			generate();
			await waitFor(() => expect(mockCreatePat).toHaveBeenCalledWith({ name: "ci" }));
		});

		it("a new key can be read only on every vault", async () => {
			openNewKey();
			allReadOnly();
			generate();
			await waitFor(() =>
				expect(mockCreatePat).toHaveBeenCalledWith({ name: "ci", default_access: "read" }),
			);
		});

		it("the All row: Write checks Read; unchecking Read unchecks Write", () => {
			openNewKey();
			fireEvent.click(box("read", ALL) as HTMLInputElement);
			expect(box("write", ALL)).not.toBeChecked();
			fireEvent.click(box("write", ALL) as HTMLInputElement);
			expect(box("read", ALL)).toBeChecked();
		});

		it("disables Review with a reason when the All row reaches nothing", () => {
			openNewKey();
			fireEvent.click(box("read", ALL) as HTMLInputElement);
			const review = screen.getByRole("button", { name: /^review$/iu });
			expect(review).toBeDisabled();
			expect(review).toHaveAccessibleDescription(/choose at least one vault/iu);
		});

		it("disables Review until the key has a name", () => {
			openNewKey();
			const field = screen.getByPlaceholderText(/ci-bot/iu);
			fireEvent.change(field, { target: { value: "  " } });
			expect(screen.getByRole("button", { name: /^review$/iu })).toBeDisabled();
			fireEvent.change(field, { target: { value: "ci" } });
			expect(screen.getByRole("button", { name: /^review$/iu })).toBeEnabled();
		});

		// The review step is the consent summary: grouped by level, named by the key.
		it("reviews the key's access before creating it", () => {
			openNewKey();
			choose();
			fireEvent.click(box("write", "work") as HTMLInputElement);
			fireEvent.click(box("read", "personal") as HTMLInputElement);
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			expect(
				screen.getByRole("heading", { level: 2, name: /^ci will be able to:$/iu }),
			).toBeInTheDocument();
			const group = (name: RegExp) =>
				within(screen.getByRole("heading", { level: 3, name }).closest("li") as HTMLElement)
					.getAllByRole("listitem")
					.map((li) => li.textContent);
			expect(group(/^can read and change notes$/iu)).toEqual(["Work"]);
			expect(group(/^can read notes$/iu)).toEqual(["Personal"]);
			expect(group(/^no access$/iu)).toEqual(["Vaults you create later"]);
			expect(mockCreatePat).not.toHaveBeenCalled();
		});

		it("Back returns to the picker with the name and every choice kept", () => {
			openNewKey();
			choose();
			fireEvent.click(box("write", "work") as HTMLInputElement);
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			fireEvent.click(screen.getByRole("button", { name: /^back$/iu }));
			expect(screen.getByPlaceholderText(/ci-bot/iu)).toHaveValue("ci");
			expect(screen.getByRole("radio", { name: /^choose vaults$/iu })).toBeChecked();
			expect(box("write", "work")).toBeChecked();
			expect(box("read", "personal")).not.toBeChecked();
		});

		it("a new key can pick a level per vault, with new vaults off by default", async () => {
			openNewKey();
			choose();
			// Nothing starts checked: Work at Read, Personal left at No access.
			fireEvent.click(box("read", "work") as HTMLInputElement);
			expect(box("read", "vaults you create later")).not.toBeChecked();
			generate();
			await waitFor(() =>
				expect(mockCreatePat).toHaveBeenCalledWith({
					name: "ci",
					// "none" repeats a none policy, so it is not sent.
					vault_access: { v2: "read" },
					default_access: "none",
				}),
			);
		});

		it("sends an unpicked vault as none when the policy would reach it", async () => {
			openNewKey();
			choose();
			fireEvent.click(box("write", "work") as HTMLInputElement);
			fireEvent.click(box("read", "vaults you create later") as HTMLInputElement);
			generate();
			await waitFor(() =>
				expect(mockCreatePat).toHaveBeenCalledWith({
					name: "ci",
					vault_access: { v1: "none", v2: "write" },
					default_access: "read",
				}),
			);
		});

		it("chosen vaults and later vaults can all be read", async () => {
			openNewKey();
			choose();
			fireEvent.click(box("read", "vaults you create later") as HTMLInputElement);
			fireEvent.click(box("read", "personal") as HTMLInputElement);
			fireEvent.click(box("read", "work") as HTMLInputElement);
			generate();
			await waitFor(() =>
				expect(mockCreatePat).toHaveBeenCalledWith({
					name: "ci",
					vault_access: { v1: "read", v2: "read" },
					default_access: "read",
				}),
			);
		});

		it("disables Review with a reason when the key reaches nothing", () => {
			openNewKey();
			choose();
			// Read all is mixed (later vaults start at none): fill, then clear.
			fireEvent.click(box("read", "all vaults") as HTMLInputElement);
			fireEvent.click(box("read", "all vaults") as HTMLInputElement);
			const review = screen.getByRole("button", { name: /^review$/iu });
			expect(review).toBeDisabled();
			expect(review).toHaveAccessibleDescription(/choose at least one vault/iu);
			// A later-vaults policy alone is a reach.
			fireEvent.click(box("read", "vaults you create later") as HTMLInputElement);
			expect(review).toBeEnabled();
		});

		it("offers no level controls to a backend without them", async () => {
			openNewKey(false);
			expect(screen.queryByRole("radio", { name: /^choose vaults$/iu })).not.toBeInTheDocument();
			expect(screen.queryByRole("checkbox")).not.toBeInTheDocument();
			generate();
			await waitFor(() => expect(mockCreatePat).toHaveBeenCalledWith({ name: "ci" }));
		});

		async function createReadOnlyKey(response: object) {
			openNewKey();
			mockCreatePat.mockResolvedValue(response);
			allReadOnly();
			generate();
			await waitFor(() => expect(mockCreatePat).toHaveBeenCalled());
		}

		it("deletes a key whose echo is missing and shows no key", async () => {
			await createReadOnlyKey({ key: "engram_k", id: "9", name: "ci" });
			await waitFor(() => expect(mockRevokePat).toHaveBeenCalledWith("9"));
			expect(await screen.findByRole("alert")).toHaveTextContent(/more access than you chose/iu);
			expect(screen.queryByRole("textbox", { name: /api key/iu })).not.toBeInTheDocument();
		});

		it("deletes a key whose echo is wider than the pick", async () => {
			await createReadOnlyKey({
				key: "engram_k",
				id: "9",
				name: "ci",
				vault_access: {},
				default_access: "write",
			});
			await waitFor(() => expect(mockRevokePat).toHaveBeenCalledWith("9"));
			expect(screen.queryByRole("textbox", { name: /api key/iu })).not.toBeInTheDocument();
		});

		it("tells the user to delete a wider key the revoke failed to remove", async () => {
			mockRevokePat.mockRejectedValueOnce(new Error("offline"));
			await createReadOnlyKey({ key: "engram_k", id: "9", name: "ci" });
			expect(await screen.findByRole("alert")).toHaveTextContent(/deleting it failed/iu);
			expect(screen.queryByRole("textbox", { name: /api key/iu })).not.toBeInTheDocument();
		});

		it("shows a key whose echo matches", async () => {
			await createReadOnlyKey({
				key: "engram_k",
				id: "9",
				name: "ci",
				vault_access: {},
				default_access: "read",
			});
			expect(await screen.findByRole("textbox", { name: /api key/iu })).toHaveValue("engram_k");
			expect(mockRevokePat).not.toHaveBeenCalled();
		});

		it("Back returns focus to the key name", () => {
			openNewKey();
			fireEvent.change(screen.getByRole("textbox", { name: /^name/iu }), {
				target: { value: "ci" },
			});
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			fireEvent.click(screen.getByRole("button", { name: /^back$/iu }));
			expect(screen.getByRole("textbox", { name: /^name/iu })).toHaveFocus();
		});

		// The vault search sits inside the key form: Enter there filters, it
		// never submits (implicit submission is the keydown's default action).
		it("Enter in the vault search does not create a key", () => {
			const extra = Array.from({ length: 8 }, (_, i) => ({
				id: `x${i}`,
				name: `Extra ${i}`,
				is_default: false,
				note_count: 0,
				attachment_count: 0,
			}));
			mockVaults.push(...extra);
			try {
				openNewKey();
				choose();
				const field = screen.getByRole("searchbox", { name: /search vaults/iu });
				const enter = createEvent.keyDown(field, { key: "Enter" });
				fireEvent(field, enter);
				expect(enter.defaultPrevented).toBe(true);
				expect(mockCreatePat).not.toHaveBeenCalled();
			} finally {
				mockVaults.splice(2);
			}
		});
	});
	// Edit access: the same pick → review flow as a new key, pre-filled with
	// what the credential has now, saved with PATCH.
	describe("edit access", () => {
		type Level = "none" | "read" | "write";
		const levels = (pairs: [string, Level][]) =>
			pairs.map(([vault_id, level]) => ({
				vault_id,
				vault_name: vault_id === "v1" ? "Personal" : "Work",
				level,
			}));

		function show(...rows: import("../api/queries").Connection[]) {
			mockConnections.splice(0, mockConnections.length, ...rows);
			mockTier = "pro";
			mockLevelsSupported = true;
			mockUpdateAccess.mockReset();
			mockVaultsQuery.current = null;
			(toast.success as ReturnType<typeof vi.fn>).mockReset();
			return renderPage();
		}

		const grant = (pairs: [string, Level][], later: Level, extra = {}) => ({
			...baseMcp,
			vault_levels: levels(pairs),
			new_vaults: later,
			...extra,
		});

		function box(column: "read" | "write", vault: string): HTMLInputElement | null {
			return screen.queryByRole("checkbox", {
				name: new RegExp(`^${column}: ${vault}$`, "iu"),
			}) as HTMLInputElement | null;
		}

		function openEdit(name = /claude desktop/iu) {
			fireEvent.click(
				screen.getByRole("button", { name: new RegExp(`edit access.*${name.source}`, "iu") }),
			);
		}

		it("opens in All vaults when every vault and later vaults share one level", () => {
			show(
				grant(
					[
						["v1", "write"],
						["v2", "write"],
					],
					"write",
				),
			);
			openEdit();
			expect(screen.getByRole("radio", { name: /^all vaults$/iu })).toBeChecked();
			expect(box("write", "all vaults, including ones you create later")).toBeChecked();
		});

		it("opens in Choose vaults with each vault's level when they differ", () => {
			show(
				grant(
					[
						["v1", "write"],
						["v2", "read"],
					],
					"none",
				),
			);
			openEdit();
			expect(screen.getByRole("radio", { name: /^choose vaults$/iu })).toBeChecked();
			expect(box("write", "personal")).toBeChecked();
			expect(box("read", "work")).toBeChecked();
			expect(box("write", "work")).not.toBeChecked();
			expect(box("read", "vaults you create later")).not.toBeChecked();
			expect(screen.getByText(/no access unless you change this here/iu)).toBeInTheDocument();
		});

		// v2 was created after the grant: the backend gives it the later level.
		it("starts a vault created since the grant at the later level", () => {
			show(grant([["v1", "write"]], "read"));
			openEdit();
			expect(screen.getByRole("radio", { name: /^choose vaults$/iu })).toBeChecked();
			expect(box("read", "work")).toBeChecked();
			expect(box("write", "work")).not.toBeChecked();
			expect(box("read", "vaults you create later")).toBeChecked();
			// The "No access" hint would contradict the checked box.
			expect(screen.queryByText(/no access unless you change this here/iu)).toBeNull();
		});

		it("reviews the result, then saves it with the exact body and updates the card", async () => {
			const row = grant(
				[
					["v1", "write"],
					["v2", "read"],
				],
				"none",
			);
			show(row);
			const saved = grant(
				[
					["v1", "write"],
					["v2", "none"],
				],
				"none",
			);
			mockUpdateAccess.mockImplementation(async () => {
				mockConnections.splice(0, mockConnections.length, saved);
				return saved;
			});
			expect(accessLines()).toContain("Can read notes Work");
			openEdit();
			fireEvent.click(box("read", "work") as HTMLInputElement);
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			const review = screen.getByRole("region", { name: /claude desktop will be able to/iu });
			expect(
				within(review).getByRole("heading", { level: 3, name: /no access/iu }),
			).toBeInTheDocument();
			// Already on Settings > Connections: no pointer back to it.
			expect(within(review).queryByText(/settings > connections/iu)).toBeNull();
			expect(mockUpdateAccess).not.toHaveBeenCalled();
			fireEvent.click(screen.getByRole("button", { name: /^save$/iu }));
			await waitFor(() =>
				expect(mockUpdateAccess).toHaveBeenCalledWith({
					connection: row,
					body: { vault_access: { v1: "write" }, default_access: "none" },
				}),
			);
			await waitFor(() => expect(screen.queryByRole("dialog")).toBeNull());
			expect(toast.success).toHaveBeenCalled();
			// The card now reads what was saved: Work is no longer readable.
			expect(accessLines()).toEqual(["Can read and change notes Personal"]);
		});

		it("sends All vaults as the policy alone", async () => {
			show({
				...basePat,
				vault_levels: levels([
					["v1", "write"],
					["v2", "none"],
				]),
				new_vaults: "none",
			});
			mockUpdateAccess.mockResolvedValue({});
			openEdit(/ci-bot/iu);
			fireEvent.click(screen.getByRole("radio", { name: /^all vaults$/iu }));
			fireEvent.click(
				box("write", "all vaults, including ones you create later") as HTMLInputElement,
			);
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			fireEvent.click(screen.getByRole("button", { name: /^save$/iu }));
			await waitFor(() =>
				expect(mockUpdateAccess).toHaveBeenCalledWith({
					connection: mockConnections[0],
					body: { default_access: "read" },
				}),
			);
		});

		it("shows a failed save on the review step and keeps the dialog open", async () => {
			show(
				grant(
					[
						["v1", "write"],
						["v2", "read"],
					],
					"none",
				),
			);
			mockUpdateAccess.mockRejectedValue(new ApiError(422, "unprocessable"));
			openEdit();
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			fireEvent.click(screen.getByRole("button", { name: /^save$/iu }));
			expect(await screen.findByRole("alert")).toHaveTextContent(/could not save/iu);
			expect(screen.getByRole("dialog")).toBeInTheDocument();
			expect(toast.success).not.toHaveBeenCalled();
		});

		it("offers no Write to a grant that asked for read only", () => {
			show(
				grant(
					[
						["v1", "read"],
						["v2", "read"],
					],
					"read",
					{ scope: "mcp:read" },
				),
			);
			openEdit();
			expect(box("read", "all vaults, including ones you create later")).toBeChecked();
			expect(box("write", "all vaults, including ones you create later")).toBeNull();
			expect(screen.getByText(/approved as read only\. reconnect it/iu)).toBeInTheDocument();
		});

		it("saves a read-only grant with no write anywhere in the body", async () => {
			show(
				grant(
					[
						["v1", "read"],
						["v2", "read"],
					],
					"read",
					{ scope: "mcp:read" },
				),
			);
			mockUpdateAccess.mockResolvedValue({});
			openEdit();
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			fireEvent.click(screen.getByRole("button", { name: /^save$/iu }));
			await waitFor(() => expect(mockUpdateAccess).toHaveBeenCalled());
			const { body } = mockUpdateAccess.mock.calls[0]![0];
			expect(body).toEqual({ default_access: "read" });
		});

		// The backend refuses an empty body; All vaults at write is the policy.
		it("saves All vaults at write as the policy, never an empty body", async () => {
			show({
				...basePat,
				vault_levels: levels([
					["v1", "write"],
					["v2", "none"],
				]),
				new_vaults: "none",
			});
			mockUpdateAccess.mockResolvedValue({});
			openEdit(/ci-bot/iu);
			fireEvent.click(screen.getByRole("radio", { name: /^all vaults$/iu }));
			expect(box("write", "all vaults, including ones you create later")).toBeChecked();
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			fireEvent.click(screen.getByRole("button", { name: /^save$/iu }));
			await waitFor(() => expect(mockUpdateAccess).toHaveBeenCalled());
			expect(mockUpdateAccess.mock.calls[0]![0].body).toEqual({ default_access: "write" });
		});

		it("pre-fills a grant with no listed vaults from its later level", () => {
			show(grant([], "write"));
			openEdit();
			expect(screen.getByRole("radio", { name: /^all vaults$/iu })).toBeChecked();
			expect(box("write", "all vaults, including ones you create later")).toBeChecked();
		});

		it("pre-fills a grant that reaches nothing as Choose vaults, Review off", () => {
			show(grant([], "none"));
			openEdit();
			expect(screen.getByRole("radio", { name: /^choose vaults$/iu })).toBeChecked();
			expect(box("read", "personal")).not.toBeChecked();
			expect(box("read", "work")).not.toBeChecked();
			expect(screen.getByRole("button", { name: /^review$/iu })).toBeDisabled();
		});

		// An empty list would send vault_access {} and replace every level the
		// user never saw on Review.
		it("offers no Review until the vault list has loaded", () => {
			show(grant([["v1", "write"]], "read"));
			mockVaultsQuery.current = { data: undefined, isLoading: true, isSuccess: false };
			openEdit();
			expect(screen.queryByRole("button", { name: /^review$/iu })).toBeNull();
			expect(screen.queryByRole("checkbox")).toBeNull();
		});

		it("shows a failed vault list instead of the picker", () => {
			show(grant([["v1", "write"]], "read"));
			mockVaultsQuery.current = {
				data: undefined,
				isLoading: false,
				isSuccess: false,
				isError: true,
				error: new ApiError(500, "boom"),
			};
			openEdit();
			expect(screen.getByRole("alert")).toBeInTheDocument();
			expect(screen.queryByRole("button", { name: /^review$/iu })).toBeNull();
		});

		it("moves focus into the dialog title on open and back to it after Back", () => {
			show(
				grant(
					[
						["v1", "write"],
						["v2", "read"],
					],
					"none",
				),
			);
			openEdit();
			const title = screen.getByRole("heading", { name: /edit access for claude desktop/iu });
			expect(title).toHaveFocus();
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			fireEvent.click(screen.getByRole("button", { name: /^back$/iu }));
			expect(
				screen.getByRole("heading", { name: /edit access for claude desktop/iu }),
			).toHaveFocus();
		});

		it("Escape in the vault search clears it first, then closes the dialog", () => {
			const extra = Array.from({ length: 8 }, (_, i) => ({
				id: `x${i}`,
				name: `Extra ${i}`,
				is_default: false,
				note_count: 0,
				attachment_count: 0,
			}));
			mockVaults.push(...extra);
			try {
				show(
					grant(
						[
							["v1", "write"],
							["v2", "read"],
						],
						"none",
					),
				);
				openEdit();
				const field = screen.getByRole("searchbox", { name: /search vaults/iu });
				fireEvent.change(field, { target: { value: "Extra" } });
				fireEvent.keyDown(field, { key: "Escape" });
				expect(field).toHaveValue("");
				expect(screen.getByRole("dialog")).toBeInTheDocument();
				fireEvent.keyDown(field, { key: "Escape" });
				expect(screen.queryByRole("dialog")).toBeNull();
			} finally {
				mockVaults.splice(2);
			}
		});

		it("offers no Edit for a key made before levels, or an Obsidian device", () => {
			show(basePat, baseObs);
			expect(screen.queryByRole("button", { name: /edit access/iu })).toBeNull();
		});

		it("Cancel saves nothing", () => {
			show(
				grant(
					[
						["v1", "write"],
						["v2", "read"],
					],
					"none",
				),
			);
			openEdit();
			fireEvent.click(screen.getByRole("button", { name: /^cancel$/iu }));
			expect(screen.queryByRole("dialog")).toBeNull();
			expect(mockUpdateAccess).not.toHaveBeenCalled();
		});
	});
});

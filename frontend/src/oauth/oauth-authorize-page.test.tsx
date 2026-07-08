import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import OAuthAuthorizePage from "./oauth-authorize-page";

const { fetchOAuthClient, postOAuthConsent } = vi.hoisted(() => ({
	fetchOAuthClient: vi.fn(),
	postOAuthConsent: vi.fn(),
}));

vi.mock("../api/oauth", () => ({ fetchOAuthClient, postOAuthConsent }));

const { apiDel } = vi.hoisted(() => ({ apiDel: vi.fn() }));

vi.mock("../api/client", () => ({
	api: { del: apiDel, get: vi.fn(), post: vi.fn(), put: vi.fn() },
}));

// /billing/status drives the proactive cap UI; default to unlimited so the
// existing tests still exercise the regular consent flow.
interface FakeBilling {
	caps: {
		obsidian_connections: number | null;
		mcp_connections: number | null;
		api_write_enabled: boolean;
		vaults: number | null;
	};
	current_connections: { obsidian: number; mcp: number };
	device_swap_cooldown_remaining_hours: number | null;
}
const billingState = vi.hoisted(() => ({
	current: {
		caps: {
			obsidian_connections: null,
			mcp_connections: null,
			api_write_enabled: true,
			vaults: null,
		},
		current_connections: { obsidian: 0, mcp: 0 },
		device_swap_cooldown_remaining_hours: null,
	} as FakeBilling,
}));

vi.mock("../api/queries", () => ({
	useMe: () => ({ data: { email: "todd@example.com" }, isLoading: false }),
	useVaults: () => ({
		data: [
			{ id: 1, name: "Personal" },
			{ id: 2, name: "Work" },
		],
		isLoading: false,
	}),
	useBillingStatus: () => ({ data: billingState.current }),
	useConnections: () => ({
		data: [
			{
				kind: "mcp",
				client_id: "existing-mcp-id",
				key_id: null,
				name: "Claude Desktop (old)",
				software_id: null,
				software_version: null,
				verified: false,
				logo: null,
				vault_id: null,
				vault_name: null,
				scope: null,
				last_used_at: null,
				connected_at: null,
				first_user_agent: null,
				first_ip: null,
				redirect_uris: [],
			},
		],
		isLoading: false,
	}),
}));

vi.mock("../theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

const VALID_QS =
	"?client_id=cli&redirect_uri=https://app/cb&response_type=code" +
	"&code_challenge=abc&code_challenge_method=S256&state=xyz&scope=vault.read";

function renderAt(qs: string) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter initialEntries={[`/oauth/consent${qs}`]}>
				<OAuthAuthorizePage />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

afterEach(() => {
	vi.clearAllMocks();
	billingState.current = {
		caps: {
			obsidian_connections: null,
			mcp_connections: null,
			api_write_enabled: true,
			vaults: null,
		},
		current_connections: { obsidian: 0, mcp: 0 },
		device_swap_cooldown_remaining_hours: null,
	};
});

describe("OAuthAuthorizePage", () => {
	it("renders the consent prompt with client name and signed-in email", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		renderAt(VALID_QS);
		expect(await screen.findByText(/Claude Desktop/u)).toBeInTheDocument();
		expect(screen.getByText(/signed in as todd@example.com/iu)).toBeInTheDocument();
	});

	it("shows the invalid-request alert when a required param is missing", () => {
		renderAt("?client_id=cli");
		expect(
			screen.getByRole("heading", { name: /invalid authorization request/iu }),
		).toBeInTheDocument();
	});

	it("renders consent when scope is ABSENT — scope is optional per RFC 6749 §4.1.1", async () => {
		// Claude Code's MCP re-auth flow omits scope (legal); the backend already
		// defaults it (oauth.ex: params["scope"] || "mcp"). Requiring it here
		// bricked every scope-less connect with 'Invalid authorization request'
		// (found 2026-07-08 during the #951 vault-deletion recovery).
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Code",
			kind: "mcp",
		});
		const NO_SCOPE_QS =
			"?client_id=cli&redirect_uri=https://app/cb&response_type=code" +
			"&code_challenge=abc&code_challenge_method=S256&state=xyz";
		renderAt(NO_SCOPE_QS);
		expect(await screen.findByText(/Claude Code/u)).toBeInTheDocument();
		expect(
			screen.queryByRole("heading", { name: /invalid authorization request/iu }),
		).not.toBeInTheDocument();
	});

	it("shows the unknown-client alert when the client lookup fails", async () => {
		fetchOAuthClient.mockRejectedValue(new Error("oauth client lookup failed: 404"));
		renderAt(VALID_QS);
		expect(await screen.findByText(/unknown oauth client/iu)).toBeInTheDocument();
	});

	it("submits consent with the chosen vault and redirects", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://app/cb?code=ok" });
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		fireEvent.click(await screen.findByRole("radio", { name: /work/iu }));
		fireEvent.click(screen.getByRole("button", { name: /approve/iu }));

		await waitFor(() =>
			expect(postOAuthConsent).toHaveBeenCalledWith(
				expect.objectContaining({ client_id: "cli", vault_choice: "vault:2" }),
			),
		);
		await waitFor(() => expect(assign).toHaveBeenCalledWith("https://app/cb?code=ok"));
	});

	it("shows a heads-up banner at the MCP cap and swaps on Approve", async () => {
		// A free-tier user already has one MCP connection — landing on /oauth/consent
		// for a new MCP client should see a heads-up banner above the normal
		// picker + Approve, and Approve disconnects the existing connection
		// BEFORE posting consent.
		billingState.current = {
			caps: { obsidian_connections: 1, mcp_connections: 1, api_write_enabled: true, vaults: null },
			current_connections: { obsidian: 0, mcp: 1 },
			device_swap_cooldown_remaining_hours: null,
		};
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		apiDel.mockResolvedValue(undefined);
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://app/cb?code=ok" });
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		// Banner names the existing connection + warns it'll be disconnected.
		expect(await screen.findByText(/Approving will disconnect/iu)).toBeInTheDocument();
		expect(screen.getByText(/Claude Desktop \(old\)/u)).toBeInTheDocument();
		// Picker + Approve are still rendered (NOT replaced).
		expect(screen.getByRole("radio", { name: /work/iu })).toBeInTheDocument();
		const approve = screen.getByRole("button", { name: /approve/iu });
		expect(approve).toBeInTheDocument();

		fireEvent.click(approve);

		// Approve opens a confirm modal first; click the confirm button there.
		const confirm = await screen.findByRole("button", {
			name: /disconnect & connect Claude Desktop/iu,
		});
		fireEvent.click(confirm);

		// Disconnect runs first, then consent.
		await waitFor(() => expect(apiDel).toHaveBeenCalledWith("/connections/oauth/existing-mcp-id"));
		await waitFor(() =>
			expect(postOAuthConsent).toHaveBeenCalledWith(expect.objectContaining({ client_id: "cli" })),
		);
		const [delOrder] = apiDel.mock.invocationCallOrder;
		const [consentOrder] = postOAuthConsent.mock.invocationCallOrder;
		expect(delOrder).toBeDefined();
		expect(consentOrder).toBeDefined();
		expect(delOrder!).toBeLessThan(consentOrder!);
		await waitFor(() => expect(assign).toHaveBeenCalledWith("https://app/cb?code=ok"));
	});

	it("cancels by redirecting back with access_denied", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		fireEvent.click(await screen.findByRole("button", { name: /cancel/iu }));

		expect(assign).toHaveBeenCalledWith("https://app/cb?error=access_denied&state=xyz");
	});
});

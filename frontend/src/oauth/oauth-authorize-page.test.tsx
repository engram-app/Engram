import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
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
// Two vaults by default — below SEARCH_THRESHOLD, so the picker renders bare.
// Tests that need the long-list behaviour swap this out.
const DEFAULT_VAULTS = [
	{
		id: "11111111-1111-1111-1111-111111111111",
		name: "Personal",
		description: null,
		is_default: true,
		note_count: 1204,
		attachment_count: 18,
	},
	{
		id: "22222222-2222-2222-2222-222222222222",
		name: "Work",
		description: "day job",
		is_default: false,
		note_count: 312,
		attachment_count: 0,
	},
];
const vaultsState = vi.hoisted(() => ({
	current: [
		{
			id: "11111111-1111-1111-1111-111111111111",
			name: "Personal",
			description: null,
			is_default: true,
			note_count: 1204,
			attachment_count: 18,
		},
		{
			id: "22222222-2222-2222-2222-222222222222",
			name: "Work",
			description: "day job",
			is_default: false,
			note_count: 312,
			attachment_count: 0,
		},
	] as Array<{
		id: string;
		name: string;
		description: string | null;
		is_default: boolean;
		note_count: number;
		attachment_count: number;
	}>,
}));

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
	useVaults: () => ({ data: vaultsState.current, isLoading: false }),
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
				redirect_uri: null,
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

function LocationProbe() {
	const location = useLocation();
	return (
		<div data-testid="location-probe">
			{location.pathname}
			{location.search}
			{location.hash}
		</div>
	);
}

function renderWithProbeAt(qs: string) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter initialEntries={[`/oauth/consent${qs}`]}>
				<LocationProbe />
				<OAuthAuthorizePage />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

afterEach(() => {
	vi.clearAllMocks();
	vaultsState.current = DEFAULT_VAULTS;
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
		expect(await screen.findByRole("heading", { name: /Claude Desktop/u })).toBeInTheDocument();
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
		expect(await screen.findByRole("heading", { name: /Claude Code/u })).toBeInTheDocument();
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
		// Every box starts checked under "All vaults", so picking Work alone
		// means unchecking Personal.
		fireEvent.click(await screen.findByRole("checkbox", { name: /personal/iu }));
		fireEvent.click(screen.getByRole("button", { name: /approve/iu }));

		await waitFor(() =>
			expect(postOAuthConsent).toHaveBeenCalledWith(
				expect.objectContaining({
					client_id: "cli",
					vault_ids: ["22222222-2222-2222-2222-222222222222"],
				}),
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
		expect(screen.getByRole("checkbox", { name: /work/iu })).toBeInTheDocument();
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

	it("clicking Upgrade in the at-cap banner keeps the OAuth query params (regression: settingsTo)", async () => {
		// Regression for the bug where `navigate({ hash: settingsHash("billing") })`
		// dropped the query string (react-router's resolvePath inherits pathname
		// but not search). Losing client_id/redirect_uri/etc mid-consent re-renders
		// this page into "Invalid authorization request", destroying the flow.
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

		renderWithProbeAt(VALID_QS);
		const upgrade = await screen.findByRole("link", { name: /upgrade/iu });
		fireEvent.click(upgrade);

		const probe = screen.getByTestId("location-probe").textContent ?? "";
		expect(probe).toContain("client_id=cli");
		expect(probe).toContain("redirect_uri=");
		expect(probe).toContain("state=xyz");
		expect(probe).toContain("#settings/billing");
		expect(
			screen.queryByRole("heading", { name: /invalid authorization request/iu }),
		).not.toBeInTheDocument();
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

	it("submits only the checked vaults", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://client.example/cb?code=x" });
		renderAt(VALID_QS);

		// Unchecking Work from the all-checked default leaves Personal — the
		// first click must narrow, not reset the selection to the box clicked.
		fireEvent.click(await screen.findByRole("checkbox", { name: /Work/ }));
		fireEvent.click(screen.getByRole("button", { name: "Approve" }));

		await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
		expect(postOAuthConsent.mock.calls[0]![0].vault_ids).toEqual([
			"11111111-1111-1111-1111-111111111111",
		]);
	});

	it("omits vault_ids entirely when All vaults is chosen", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://client.example/cb?code=x" });
		renderAt(VALID_QS);

		fireEvent.click(await screen.findByRole("checkbox", { name: /Personal/ }));
		fireEvent.click(screen.getByRole("radio", { name: /All vaults/ }));
		fireEvent.click(screen.getByRole("button", { name: "Approve" }));

		await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
		expect(postOAuthConsent.mock.calls[0]![0].vault_ids).toBeUndefined();
	});

	it("sends the typed label", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://client.example/cb?code=x" });
		renderAt(VALID_QS);

		fireEvent.click(await screen.findByRole("checkbox", { name: /Personal/ }));
		fireEvent.change(screen.getByLabelText(/Name this connection/), {
			target: { value: "Work laptop" },
		});
		fireEvent.click(screen.getByRole("button", { name: "Approve" }));

		await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
		expect(postOAuthConsent.mock.calls[0]![0].label).toBe("Work laptop");
	});

	// The input is prefilled via `placeholder`, never `value` — a default the
	// user never touched must not be submitted as if they had chosen it.
	it("omits the label when left at the prefilled default", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://client.example/cb?code=x" });
		renderAt(VALID_QS);

		fireEvent.click(await screen.findByRole("checkbox", { name: /Personal/ }));
		expect(screen.getByLabelText(/Name this connection/)).toHaveValue("");
		fireEvent.click(screen.getByRole("button", { name: "Approve" }));

		await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
		expect(postOAuthConsent.mock.calls[0]![0].label).toBeUndefined();
	});

	it("disables Approve once the checked vaults drop to zero", async () => {
		// Default state (nothing touched) is the "All vaults" grant, which is a
		// valid submission on its own — so Approve starts enabled. Once the user
		// switches into picking specific vaults and unchecks the last one, that
		// is a zero-vault grant and must block submission.
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		renderAt(VALID_QS);
		const work = await screen.findByRole("checkbox", { name: /Work/ });
		const personal = screen.getByRole("checkbox", { name: /Personal/ });

		fireEvent.click(work);
		expect(screen.getByRole("button", { name: "Approve" })).toBeEnabled();

		fireEvent.click(personal);
		expect(screen.getByRole("button", { name: "Approve" })).toBeDisabled();

		fireEvent.click(personal);
		expect(screen.getByRole("button", { name: "Approve" })).toBeEnabled();
	});

	it("checks every vault box under All vaults, and unchecking one keeps the rest", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		renderAt(VALID_QS);

		const work = await screen.findByRole("checkbox", { name: /Work/ });
		const personal = screen.getByRole("checkbox", { name: /Personal/ });
		expect(screen.getByRole("radio", { name: /All vaults/ })).toBeChecked();
		expect(work).toBeChecked();
		expect(personal).toBeChecked();

		fireEvent.click(work);
		expect(screen.getByRole("radio", { name: /All vaults/ })).not.toBeChecked();
		expect(work).not.toBeChecked();
		expect(personal).toBeChecked();
	});

	describe("a vault list long enough to need searching", () => {
		function manyVaults(n: number) {
			return Array.from({ length: n }, (_, i) => ({
				id: `${String(i).padStart(8, "0")}-0000-0000-0000-000000000000`,
				name: i === 0 ? "Personal" : `Project ${i}`,
				description: null,
				is_default: i === 0,
				note_count: 0,
				attachment_count: 0,
			}));
		}

		// The search field is a second text input on a screen whose real question
		// is the checkbox list, so it stays behind the toggle until asked for.
		it("hides the field behind a toggle until it is asked for", async () => {
			vaultsState.current = manyVaults(12);
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
			renderAt(VALID_QS);

			await screen.findByRole("checkbox", { name: /Personal/ });
			expect(screen.queryByRole("searchbox")).toBeNull();

			fireEvent.click(screen.getByRole("button", { name: /Search vaults/iu }));
			expect(screen.getByRole("searchbox", { name: /Search vaults/iu })).toBeInTheDocument();
		});

		it("stays out of the way while every vault fits on screen", async () => {
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
			renderAt(VALID_QS);

			await screen.findByRole("checkbox", { name: /Personal/ });
			expect(screen.queryByRole("searchbox")).toBeNull();
			expect(screen.queryByRole("button", { name: /Search vaults/iu })).toBeNull();
		});

		it("filters the rows without changing what is selected", async () => {
			vaultsState.current = manyVaults(12);
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
			postOAuthConsent.mockResolvedValue({ redirect_uri: "https://client.example/cb?code=x" });
			renderAt(VALID_QS);

			// Drop one vault, so the grant is an explicit 11-of-12 set.
			fireEvent.click(await screen.findByRole("checkbox", { name: /Project 5/ }));

			// The count rides with the search field — it exists to account for
			// selections the filter has hidden, so it has no job before then.
			fireEvent.click(screen.getByRole("button", { name: /Search vaults/iu }));
			expect(screen.getByText("11 of 12 selected")).toBeInTheDocument();

			const search = screen.getByRole("searchbox", { name: /Search vaults/iu });
			fireEvent.change(search, { target: { value: "Project 1" } });

			// Project 1, 10, 11 match; Personal and Project 5 are hidden.
			expect(screen.queryByRole("checkbox", { name: /Personal/ })).toBeNull();
			expect(screen.queryByRole("checkbox", { name: /Project 5/ })).toBeNull();
			expect(screen.getByRole("checkbox", { name: /Project 10/ })).toBeInTheDocument();
			// Hiding a row must not deselect it — the count is unmoved.
			expect(screen.getByText("11 of 12 selected")).toBeInTheDocument();

			fireEvent.click(screen.getByRole("button", { name: "Approve" }));
			await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
			expect(postOAuthConsent.mock.calls[0]![0].vault_ids).toHaveLength(11);
		});

		it("keeps All vaults reachable when nothing matches", async () => {
			vaultsState.current = manyVaults(12);
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
			renderAt(VALID_QS);

			fireEvent.click(await screen.findByRole("button", { name: /Search vaults/iu }));
			const search = screen.getByRole("searchbox", { name: /Search vaults/iu });
			fireEvent.change(search, { target: { value: "zzzz" } });

			expect(screen.getByText(/No vaults match/)).toBeInTheDocument();
			// It sits outside the filtered list on purpose.
			expect(screen.getByRole("radio", { name: /All vaults/ })).toBeInTheDocument();
		});
	});

	it("shows counts and the default badge", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		renderAt(VALID_QS);
		expect(await screen.findByText("1,204 notes · 18 files")).toBeInTheDocument();
		expect(screen.getByText("default")).toBeInTheDocument();
		expect(screen.getByText("day job")).toBeInTheDocument();
	});
});

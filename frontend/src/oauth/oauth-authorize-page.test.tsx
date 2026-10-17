import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { StrictMode } from "react";
import { MemoryRouter, useLocation } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import type { OAuthConsentParams } from "../api/oauth";
import OAuthAuthorizePage from "./oauth-authorize-page";
import { peekPendingAuthorization } from "./pending-authorization";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

const { fetchOAuthClient, postOAuthConsent } = vi.hoisted(() => ({
	fetchOAuthClient: vi.fn(),
	postOAuthConsent: vi.fn(),
}));

vi.mock("../api/oauth", () => ({ fetchOAuthClient, postOAuthConsent }));

const { apiDel } = vi.hoisted(() => ({ apiDel: vi.fn() }));

vi.mock("../api/client", async (importOriginal) => ({
	ApiError: (await importOriginal<typeof import("../api/client")>()).ApiError,
	api: { del: apiDel, get: vi.fn(), post: vi.fn(), put: vi.fn() },
}));

// /billing/status drives the proactive cap UI; default to unlimited so the
// existing tests still exercise the regular consent flow.
interface FakeBilling {
	caps: {
		obsidian_connections: number | null;
		vaults: number | null;
	};
	current_connections: { obsidian: number };
	device_swap_cooldown_remaining_hours: number | null;
}
// Two vaults by default — below SEARCH_THRESHOLD, so the picker renders bare.
// Tests that need the long-list behaviour swap this out.
const DEFAULT_VAULTS = [
	{
		id: "11111111-1111-1111-1111-111111111111",
		name: "Personal",
		is_default: true,
		note_count: 1204,
		attachment_count: 18,
	},
	{
		id: "22222222-2222-2222-2222-222222222222",
		name: "Work",
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
			is_default: true,
			note_count: 1204,
			attachment_count: 18,
		},
		{
			id: "22222222-2222-2222-2222-222222222222",
			name: "Work",
			is_default: false,
			note_count: 312,
			attachment_count: 0,
		},
	] as Array<{
		id: string;
		name: string;
		is_default: boolean;
		note_count: number;
		attachment_count: number;
	}>,
}));

// Defaults to a fully onboarded user so every pre-existing test keeps
// exercising the consent card rather than the bounce.
const onboardingState = vi.hoisted(() => ({
	current: { next_step: "done", gate_ok: true, profile: { tools: ["claude"] } } as {
		next_step: string;
		// The page reads THIS, not `next_step`. They disagree for obsidian-path
		// users, who the gate admits while the wizard still parks them on
		// "vault" awaiting the plugin's first sync.
		gate_ok: boolean;
		profile?: { tools?: string[] };
	},
}));

const { setProfileMock } = vi.hoisted(() => ({ setProfileMock: vi.fn() }));

const billingState = vi.hoisted(() => ({
	current: {
		caps: {
			obsidian_connections: null,
			vaults: null,
		},
		current_connections: { obsidian: 0 },
		device_swap_cooldown_remaining_hours: null,
	} as FakeBilling,
}));

// Whether the backend advertises per-vault access levels (#174). A backend that
// predates them would silently ignore the level fields and mint full access.
const accessLevelsState = vi.hoisted(() => ({ current: true }));

vi.mock("../api/queries", () => ({
	useMe: () => ({ data: { email: "todd@example.com" }, isLoading: false }),
	useVaults: () => ({ data: vaultsState.current, isLoading: false }),
	useAccessLevelsSupported: () => accessLevelsState.current,
	useBillingStatus: () => ({ data: billingState.current }),
	useOnboardingStatus: () => ({ data: onboardingState.current, isLoading: false }),
	useSetOnboardingProfile: () => ({ mutateAsync: setProfileMock }),
	useConnections: () => ({
		data: [
			{
				kind: "obsidian",
				client_id: "existing-obsidian-id",
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

// A backend that supports levels echoes what it stored. These tests model one
// that stored exactly what was asked for; the echo tests below break that.
function echoOf(body: OAuthConsentParams) {
	return {
		scope: body.read_only ? "mcp:read" : body.scope,
		vault_access: body.vault_access ?? {},
		default_access: body.default_access ?? (body.vault_access ? "none" : "write"),
	};
}

function consentRedirectsTo(redirect_uri: string) {
	postOAuthConsent.mockImplementation(async (body: OAuthConsentParams) => ({
		redirect_uri,
		granted: echoOf(body),
	}));
}

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

// The vault table sits behind "Choose vaults", the same picker as the New API
// Key dialog.
async function choosePerVault() {
	fireEvent.click(await screen.findByRole("radio", { name: /^choose vaults$/iu }));
}

// Choose vaults starts with nothing checked. Many tests start from every
// vault at Read and write and later vaults at No access instead.
async function choosePerVaultAllWrite() {
	await choosePerVault();
	fireEvent.click(box("write", "all vaults") as HTMLInputElement);
	setLevel("vaults you create later", "none");
}

// By label, not role: a role query computes the accessible name of every
// checkbox on the page (each a getComputedStyle walk in happy-dom), ~20ms a
// call on a long list, and these tests make dozens. The aria-label IS the name.
function box(column: "read" | "write", vault: string): HTMLInputElement | null {
	return screen.queryByLabelText(new RegExp(`^${column}: ${vault}$`, "iu"), {
		selector: "input[type=checkbox]",
	}) as HTMLInputElement | null;
}

// A level is a pair of boxes: Read alone is read, Write (which checks Read)
// is write, neither is none.
function setLevel(vault: string, level: "none" | "read" | "write") {
	const read = box("read", vault);
	const write = box("write", vault);
	if (!read) {
		throw new Error(`no Read box for ${vault}`);
	}
	if (level === "write") {
		if (!write?.checked) {
			fireEvent.click(write as HTMLInputElement);
		}
		return;
	}
	if (write?.checked) {
		fireEvent.click(write);
	}
	if ((level === "read") !== read.checked) {
		fireEvent.click(read);
	}
}

// "All vaults" is one table row with the same Read and Write boxes.
const ALL = "all vaults, including ones you create later";

function allReadOnly() {
	fireEvent.click(box("write", ALL) as HTMLInputElement);
}

// Consent is two steps: Review, then Approve on the summary.
function approve() {
	fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
	fireEvent.click(screen.getByRole("button", { name: /^approve$/iu }));
}

afterEach(() => {
	vi.clearAllMocks();
	vaultsState.current = DEFAULT_VAULTS;
	accessLevelsState.current = true;
	billingState.current = {
		caps: {
			obsidian_connections: null,
			vaults: null,
		},
		current_connections: { obsidian: 0 },
		device_swap_cooldown_remaining_hours: null,
	};
});

// Signing up happens inside the OAuth flow, so this page can be reached by an
// account with nothing set up. Approving there mints a grant the vault gate
// refuses on every call (#1666), so the request is parked and the user is sent
// through the wizard first.
describe("OAuthAuthorizePage onboarding bounce", () => {
	const ANTIGRAVITY = {
		client_id: "cli",
		client_name: "Google Antigravity",
		kind: "mcp" as const,
		slug: "antigravity",
	};

	afterEach(() => {
		onboardingState.current = { next_step: "done", gate_ok: true, profile: { tools: ["claude"] } };
		window.sessionStorage.clear();
	});

	function probeText(): string {
		return screen.getByTestId("location-probe").textContent ?? "";
	}

	it("sends an unfinished user to the wizard instead of offering Approve", async () => {
		onboardingState.current = { next_step: "agreement", gate_ok: false };
		fetchOAuthClient.mockResolvedValue(ANTIGRAVITY);

		renderWithProbeAt(VALID_QS);

		await waitFor(() => expect(probeText()).toContain("/onboard"));
		expect(screen.queryByRole("button", { name: /review|approve/iu })).toBeNull();
	});

	// The whole request, query string included, so `state` and the PKCE
	// challenge survive and the original authorization is still honored.
	it("parks the request so the wizard can bring them back to it", async () => {
		onboardingState.current = { next_step: "agreement", gate_ok: false };
		fetchOAuthClient.mockResolvedValue(ANTIGRAVITY);

		renderWithProbeAt(VALID_QS);

		await waitFor(() =>
			expect(window.sessionStorage.getItem("engram:pending-oauth")).toContain("/oauth/consent"),
		);
		expect(window.sessionStorage.getItem("engram:pending-oauth")).toContain("state=xyz");
	});

	// The wizard's Cancel trusts the parked redirect only as far as the backend did.
	it("parks whether the backend confirmed the redirect", async () => {
		onboardingState.current = { next_step: "agreement", gate_ok: false };
		fetchOAuthClient.mockResolvedValue({ ...ANTIGRAVITY, redirect_uri_registered: true });

		renderWithProbeAt(VALID_QS);

		await waitFor(() => expect(peekPendingAuthorization()?.redirectVerified).toBe(true));
	});

	it("parks an unconfirmed redirect as unverified", async () => {
		onboardingState.current = { next_step: "agreement", gate_ok: false };
		fetchOAuthClient.mockResolvedValue(ANTIGRAVITY);

		renderWithProbeAt(VALID_QS);

		await waitFor(() => expect(peekPendingAuthorization()).not.toBeNull());
		expect(peekPendingAuthorization()?.redirectVerified).toBe(false);
	});

	it("pre-answers the tool question from the connecting client", async () => {
		onboardingState.current = { next_step: "agreement", gate_ok: false };
		fetchOAuthClient.mockResolvedValue(ANTIGRAVITY);

		renderWithProbeAt(VALID_QS);

		// `tools_prefilled` is what tells the backend this answer came from the
		// OAuth client rather than the user, which is what drops the tools step
		// from the chain. Without it an ordinary signup's counter would freeze.
		await waitFor(() =>
			expect(setProfileMock).toHaveBeenCalledWith({
				tools: ["antigravity"],
				tools_prefilled: true,
			}),
		);
	});

	// Self-host: the pre-answer alone provisions the connector vault, so the
	// status refetched inside the mutation already says gate_ok while this
	// page is still mounted. Clearing then sent the user home, not back here.
	it("keeps the park when the pre-answer itself satisfies the gate", async () => {
		onboardingState.current = { next_step: "vault", gate_ok: false };
		fetchOAuthClient.mockResolvedValue(ANTIGRAVITY);
		let rerender: () => void = () => {};
		setProfileMock.mockImplementation(async () => {
			onboardingState.current = {
				next_step: "done",
				gate_ok: true,
				profile: { tools: ["antigravity"] },
			};
			// The refetch lands before mutateAsync resolves (onSuccess awaits it).
			await act(async () => rerender());
		});

		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		const tree = () => (
			<QueryClientProvider client={qc}>
				<MemoryRouter initialEntries={[`/oauth/consent${VALID_QS}`]}>
					<LocationProbe />
					<OAuthAuthorizePage />
				</MemoryRouter>
			</QueryClientProvider>
		);
		const view = render(tree());
		rerender = () => view.rerender(tree());

		await waitFor(() => expect(setProfileMock).toHaveBeenCalled());
		await waitFor(() => expect(probeText()).toContain("/onboard"));
		expect(window.sessionStorage.getItem("engram:pending-oauth")).toContain("state=xyz");
	});

	it("invents no answer for a client it cannot attribute", async () => {
		onboardingState.current = { next_step: "agreement", gate_ok: false };
		fetchOAuthClient.mockResolvedValue({ ...ANTIGRAVITY, slug: null });

		renderWithProbeAt(VALID_QS);

		await waitFor(() => expect(probeText()).toContain("/onboard"));
		expect(setProfileMock).not.toHaveBeenCalled();
	});

	it("does not overwrite tools the user already answered", async () => {
		onboardingState.current = {
			next_step: "billing",
			gate_ok: false,
			profile: { tools: ["cursor"] },
		};
		fetchOAuthClient.mockResolvedValue(ANTIGRAVITY);

		renderWithProbeAt(VALID_QS);

		await waitFor(() => expect(probeText()).toContain("/onboard"));
		expect(setProfileMock).not.toHaveBeenCalled();
	});

	it("leaves a finished user on consent and drops a stale park", async () => {
		window.sessionStorage.setItem(
			"engram:pending-oauth",
			JSON.stringify({ returnTo: "/oauth/consent?old=1", toolSlug: null }),
		);
		fetchOAuthClient.mockResolvedValue(ANTIGRAVITY);

		renderAt(VALID_QS);

		expect(await screen.findByRole("button", { name: /^review$/iu })).toBeTruthy();
		expect(window.sessionStorage.getItem("engram:pending-oauth")).toBeNull();
	});
});

// Someone who signed up inside the connector flow has never seen their vault.
// Approving sends this tab back to the client, so the vault opens in another.
describe("OAuthAuthorizePage vault tab after a signup detour", () => {
	const CLIENT = { client_id: "cli", client_name: "ChatGPT", kind: "mcp" as const };

	afterEach(() => {
		window.sessionStorage.clear();
	});

	function parkThisRequest() {
		window.sessionStorage.setItem(
			"engram:pending-oauth",
			JSON.stringify({ returnTo: `/oauth/consent${VALID_QS}`, toolSlug: null }),
		);
	}

	it("opens the vault in a new tab on Approve", async () => {
		parkThisRequest();
		fetchOAuthClient.mockResolvedValue(CLIENT);
		consentRedirectsTo("https://app/cb?code=ok");
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
		const open = vi.spyOn(window, "open").mockReturnValue(null);

		renderAt(VALID_QS);
		await screen.findByRole("button", { name: /^review$/iu });
		approve();

		// Synchronously, inside the click: a popup blocker refuses one opened
		// after the consent request resolves.
		expect(open).toHaveBeenCalledWith("/", "_blank");
		await waitFor(() => expect(assign).toHaveBeenCalledWith("https://app/cb?code=ok"));
	});

	it("closes the tab when the consent fails", async () => {
		parkThisRequest();
		fetchOAuthClient.mockResolvedValue(CLIENT);
		postOAuthConsent.mockRejectedValue(new Error("boom"));
		const close = vi.fn();
		vi.spyOn(window, "open").mockReturnValue({ close } as unknown as Window);

		renderAt(VALID_QS);
		await screen.findByRole("button", { name: /^review$/iu });
		approve();

		await waitFor(() => expect(close).toHaveBeenCalled());
	});

	it("opens nothing for a user who did not just sign up", async () => {
		fetchOAuthClient.mockResolvedValue(CLIENT);
		consentRedirectsTo("https://app/cb?code=ok");
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
		const open = vi.spyOn(window, "open").mockReturnValue(null);

		renderAt(VALID_QS);
		await screen.findByRole("button", { name: /^review$/iu });
		approve();

		await waitFor(() => expect(assign).toHaveBeenCalled());
		expect(open).not.toHaveBeenCalled();
	});

	// A park left by some other request is not this user's return trip.
	it("opens nothing on a stale park from a different request", async () => {
		window.sessionStorage.setItem(
			"engram:pending-oauth",
			JSON.stringify({ returnTo: "/oauth/consent?old=1", toolSlug: null }),
		);
		fetchOAuthClient.mockResolvedValue(CLIENT);
		consentRedirectsTo("https://app/cb?code=ok");
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
		const open = vi.spyOn(window, "open").mockReturnValue(null);

		renderAt(VALID_QS);
		await screen.findByRole("button", { name: /^review$/iu });
		approve();

		await waitFor(() => expect(assign).toHaveBeenCalled());
		expect(open).not.toHaveBeenCalled();
	});
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

	// A link straight to /oauth/consent with a real client_id and someone else's
	// redirect_uri made Cancel an open redirect off our origin (RFC 9700 §4.11).
	it("refuses a redirect the client never registered: no Approve, no Cancel", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude",
			kind: "mcp",
			slug: null,
			redirect_uri_registered: false,
			redirect_host: null,
		});
		renderAt(VALID_QS);
		expect(
			await screen.findByRole("heading", { name: /invalid authorization request/iu }),
		).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: /approve/iu })).toBeNull();
		expect(screen.queryByRole("button", { name: /cancel/iu })).toBeNull();
	});

	// MCP 2025-11-25: the user sees where the authorization code is sent.
	it("shows the host the user will be returned to", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude",
			kind: "mcp",
			slug: null,
			redirect_uri_registered: true,
			redirect_host: "app",
		});
		renderAt(VALID_QS);
		expect(await screen.findByText(/you will return to app/iu)).toBeInTheDocument();
	});

	// Cancel fails closed: a backend that does not confirm the redirect (an
	// older one, or a missing field) gets Approve, which it re-validates, but no
	// Cancel, which would redirect on this page's word alone.
	it("offers no Cancel when the redirect is not confirmed", async () => {
		fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Claude", kind: "mcp" });
		renderAt(VALID_QS);
		expect(await screen.findByRole("button", { name: /^review$/iu })).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: /cancel/iu })).toBeNull();
	});

	// MCP 2025-11-25: a metadata-document client is shown by its host.
	it("shows the host the client's metadata document lives on", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "https://claude.ai/oauth/claude-code-client-metadata",
			client_name: "Claude Code",
			kind: "mcp",
			redirect_uri_registered: true,
			client_host: "claude.ai",
		});
		renderAt(VALID_QS);
		expect(await screen.findByText(/app details from claude\.ai/iu)).toBeInTheDocument();
	});

	// MCP 2025-11-25 "Localhost Redirect URI Risks": any local process can claim
	// a vendor's client_id on a loopback port.
	it("warns when the redirect is on this computer", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Code",
			kind: "mcp",
			slug: null,
			redirect_uri_registered: true,
			redirect_host: "localhost",
			redirect_loopback: true,
		});
		renderAt(VALID_QS);
		expect(await screen.findByText(/an app on this computer/iu)).toBeInTheDocument();
	});

	it("does not warn for a web redirect", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude",
			kind: "mcp",
			slug: null,
			redirect_uri_registered: true,
			redirect_host: "app",
			redirect_loopback: false,
		});
		renderAt(VALID_QS);
		await screen.findByText(/you will return to app/iu);
		expect(screen.queryByText(/an app on this computer/iu)).toBeNull();
	});

	// RFC 9207 §2: an error response carries `iss` too.
	it("puts iss on the Cancel redirect when the server sent one", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude",
			kind: "mcp",
			redirect_uri_registered: true,
		});
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
		const iss = "https://mcp.engram.page";

		renderAt(`${VALID_QS}&iss=${encodeURIComponent(iss)}`);
		fireEvent.click(await screen.findByRole("button", { name: /cancel/iu }));
		expect(assign).toHaveBeenCalledWith(
			`https://app/cb?error=access_denied&state=xyz&iss=${encodeURIComponent(iss)}`,
		);
	});

	// RFC 6749 §4.1.1: `state` is RECOMMENDED, not required. A client that omits
	// it must still reach consent, and Cancel must not invent an empty one.
	it("renders consent and cancels cleanly when state is absent", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude",
			kind: "mcp",
			redirect_uri_registered: true,
		});
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
		const NO_STATE_QS =
			"?client_id=cli&redirect_uri=https://app/cb&response_type=code" +
			"&code_challenge=abc&code_challenge_method=S256";

		renderAt(NO_STATE_QS);
		fireEvent.click(await screen.findByRole("button", { name: /cancel/iu }));
		expect(assign).toHaveBeenCalledWith("https://app/cb?error=access_denied");
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
		consentRedirectsTo("https://app/cb?code=ok");
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		// Choose vaults starts with nothing checked; pick Work.
		await choosePerVault();
		setLevel("work", "write");
		approve();

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

	it("emits mcp_connect_attempted and mcp_connect_succeeded, mapping a recognised slug", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Cursor",
			kind: "mcp",
			slug: "cursor",
		});
		consentRedirectsTo("https://app/cb?code=ok");
		vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		await screen.findByRole("button", { name: /^review$/iu });
		approve();

		expect(mockTrack).toHaveBeenCalledWith("mcp_connect_attempted", { client: "cursor" });
		await waitFor(() =>
			expect(mockTrack).toHaveBeenCalledWith("mcp_connect_succeeded", { client: "cursor" }),
		);
	});

	it("maps an unrecognised or absent slug to 'other', never the raw value", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Some New Client",
			kind: "mcp",
			slug: "some_new_client",
		});
		consentRedirectsTo("https://app/cb?code=ok");
		vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		await screen.findByRole("button", { name: /^review$/iu });
		approve();

		expect(mockTrack).toHaveBeenCalledWith("mcp_connect_attempted", { client: "other" });
	});

	it("emits mcp_connect_failed when consent rejects", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
			slug: "claude",
		});
		postOAuthConsent.mockRejectedValue(new Error("boom"));

		renderAt(VALID_QS);
		await screen.findByRole("button", { name: /^review$/iu });
		approve();

		await waitFor(() =>
			expect(mockTrack).toHaveBeenCalledWith(
				"mcp_connect_failed",
				expect.objectContaining({ client: "claude" }),
			),
		);
	});

	it("shows a heads-up banner at the Obsidian cap and swaps on Approve", async () => {
		// A free-tier user already at the Obsidian connection cap — landing on
		// /oauth/consent for a new Obsidian client should see a heads-up banner above the normal
		// picker + Approve, and Approve disconnects the existing connection
		// BEFORE posting consent.
		billingState.current = {
			caps: { obsidian_connections: 2, vaults: null },
			current_connections: { obsidian: 2 },
			device_swap_cooldown_remaining_hours: null,
		};
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "obsidian",
		});
		apiDel.mockResolvedValue(undefined);
		consentRedirectsTo("https://app/cb?code=ok");
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		// Banner names the existing connection + warns it'll be disconnected.
		expect(await screen.findByText(/Approving will disconnect/iu)).toBeInTheDocument();
		expect(screen.getByText(/Claude Desktop \(old\)/u)).toBeInTheDocument();
		// The served cap, not a hardcoded 1.
		expect(screen.getByRole("status")).toHaveTextContent(/device limit is 2\./iu);
		// Picker + Approve are still rendered (NOT replaced).
		expect(screen.getByRole("radio", { name: /^choose vaults$/iu })).toBeInTheDocument();
		approve();

		// Approve opens a confirm modal first; click the confirm button there.
		const confirm = await screen.findByRole("button", {
			name: /disconnect & connect Claude Desktop/iu,
		});
		expect(screen.getByRole("dialog")).toHaveTextContent(/device limit is 2\./iu);
		fireEvent.click(confirm);

		// Disconnect runs first, then consent.
		await waitFor(() =>
			expect(apiDel).toHaveBeenCalledWith("/connections/device/existing-obsidian-id"),
		);
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

	// #1974: MCP connections are uncapped on every tier, so consent for an MCP
	// client never shows the cap banner, whatever the user already has.
	it("never shows a cap banner for an MCP client", async () => {
		billingState.current = {
			caps: { obsidian_connections: 1, vaults: null },
			current_connections: { obsidian: 1 },
			device_swap_cooldown_remaining_hours: null,
		};
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});

		renderAt(VALID_QS);
		expect(await screen.findByRole("button", { name: /^review$/iu })).toBeInTheDocument();
		expect(screen.queryByText(/Approving will disconnect/iu)).not.toBeInTheDocument();
	});

	it("clicking Upgrade in the at-cap banner keeps the OAuth query params (regression: settingsTo)", async () => {
		// Regression for the bug where `navigate({ hash: settingsHash("billing") })`
		// dropped the query string (react-router's resolvePath inherits pathname
		// but not search). Losing client_id/redirect_uri/etc mid-consent re-renders
		// this page into "Invalid authorization request", destroying the flow.
		billingState.current = {
			caps: { obsidian_connections: 1, vaults: null },
			current_connections: { obsidian: 1 },
			device_swap_cooldown_remaining_hours: null,
		};
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "obsidian",
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

	// RFC 9207: /oauth/authorize fixes the issuer on the host the client dialed;
	// the page carries it to consent, which echoes it only if it is ours.
	it("forwards iss from the authorize redirect to consent", async () => {
		fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Claude", kind: "mcp" });
		postOAuthConsent.mockResolvedValue({ redirect_uri: "https://app/cb?code=ok" });
		vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(`${VALID_QS}&iss=${encodeURIComponent("https://mcp.engram.page")}`);
		await screen.findByRole("button", { name: /^review$/iu });
		approve();

		await waitFor(() =>
			expect(postOAuthConsent).toHaveBeenCalledWith(
				expect.objectContaining({ iss: "https://mcp.engram.page" }),
			),
		);
	});

	it("cancels by redirecting back with access_denied", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
			redirect_uri_registered: true,
		});
		const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		fireEvent.click(await screen.findByRole("button", { name: /cancel/iu }));

		expect(assign).toHaveBeenCalledWith("https://app/cb?error=access_denied&state=xyz");
	});

	// #1974: a denial never reaches the server, so it is only visible here.
	it("emits mcp_connect_denied on cancel", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
			slug: "claude",
			redirect_uri_registered: true,
		});
		vi.spyOn(window.location, "assign").mockImplementation(() => {});

		renderAt(VALID_QS);
		fireEvent.click(await screen.findByRole("button", { name: /cancel/iu }));

		expect(mockTrack).toHaveBeenCalledWith("mcp_connect_denied", { client: "claude" });
	});

	it("submits only the checked vaults", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		consentRedirectsTo("https://client.example/cb?code=x");
		renderAt(VALID_QS);

		await choosePerVault();
		setLevel("personal", "write");
		approve();

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
		consentRedirectsTo("https://client.example/cb?code=x");
		renderAt(VALID_QS);

		await choosePerVault();
		setLevel("personal", "none");
		fireEvent.click(screen.getByRole("radio", { name: /All vaults/ }));
		approve();

		await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
		expect(postOAuthConsent.mock.calls[0]![0].vault_ids).toBeUndefined();
	});

	it("sends the typed label", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		consentRedirectsTo("https://client.example/cb?code=x");
		renderAt(VALID_QS);

		await choosePerVault();
		setLevel("work", "write");
		fireEvent.change(screen.getByLabelText(/Name this connection/), {
			target: { value: "Work laptop" },
		});
		approve();

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
		consentRedirectsTo("https://client.example/cb?code=x");
		renderAt(VALID_QS);

		await choosePerVault();
		setLevel("work", "write");
		expect(screen.getByLabelText(/Name this connection/)).toHaveValue("");
		approve();

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
		await choosePerVault();
		setLevel("work", "write");
		setLevel("personal", "write");

		setLevel("work", "none");
		expect(screen.getByRole("button", { name: /^review$/iu })).toBeEnabled();

		setLevel("personal", "none");
		expect(screen.getByRole("button", { name: /^review$/iu })).toBeDisabled();

		setLevel("personal", "read");
		expect(screen.getByRole("button", { name: /^review$/iu })).toBeEnabled();
	});

	// Scope first (All vaults / Choose vaults), then Read only, then the table.
	describe("vault picker", () => {
		function mcp() {
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
		}

		it("defaults to All vaults: one row, Read and Write both on", async () => {
			mcp();
			renderAt(VALID_QS);
			const group = await screen.findByRole("group", {
				name: /which vaults can claude desktop access/iu,
			});
			const all = within(group).getByRole("radio", { name: /^all vaults$/iu });
			const choose = within(group).getByRole("radio", { name: /^choose vaults$/iu });
			expect(all).toBeChecked();
			const [row] = screen.getAllByRole("listitem");
			expect(row).toHaveTextContent(/^All vaults, including ones you create later/u);
			// One row has nothing to select all of.
			expect(screen.getAllByRole("checkbox")).toHaveLength(2);
			expect(box("read", ALL)).toBeChecked();
			expect(box("write", ALL)).toBeChecked();
			expect(screen.queryByRole("switch")).toBeNull();

			fireEvent.click(choose);
			expect(choose).toBeChecked();
			// Choosing vaults starts from nothing: the user picks each one.
			for (const vault of ["work", "personal", "vaults you create later"]) {
				expect(box("read", vault)).not.toBeChecked();
				expect(box("write", vault)).not.toBeChecked();
			}
			expect(screen.getByRole("button", { name: /^review$/iu })).toBeDisabled();
		});

		// Each box carries its visible word; the accessible name adds the row.
		it("labels every box, in every row", async () => {
			mcp();
			renderAt(VALID_QS);
			await choosePerVault();
			for (const vault of ["work", "personal", "vaults you create later", "all vaults"]) {
				expect(box("read", vault)?.closest("label")).toHaveTextContent(/^Read$/u);
				expect(box("write", vault)?.closest("label")).toHaveTextContent(/^Write$/u);
			}
			expect(box("write", "vaults you create later")).not.toBeChecked();
			expect(box("read", "vaults you create later")).not.toBeChecked();
		});

		it("checking Write checks Read; unchecking Read unchecks Write", async () => {
			mcp();
			renderAt(VALID_QS);
			await choosePerVault();
			setLevel("work", "write");
			fireEvent.click(box("read", "work") as HTMLInputElement);
			expect(box("read", "work")).not.toBeChecked();
			expect(box("write", "work")).not.toBeChecked();

			fireEvent.click(box("write", "work") as HTMLInputElement);
			expect(box("write", "work")).toBeChecked();
			expect(box("read", "work")).toBeChecked();

			fireEvent.click(box("write", "work") as HTMLInputElement);
			expect(box("write", "work")).not.toBeChecked();
			expect(box("read", "work")).toBeChecked();
		});

		// Select-all covers the vaults it acts on AND the later-vaults row (a
		// user decision), so later vaults count toward the tri-state.
		it("each header box is a tri-state select-all over every vault and later vaults", async () => {
			mcp();
			renderAt(VALID_QS);
			await choosePerVault();
			const allRead = box("read", "all vaults") as HTMLInputElement;
			const allWrite = box("write", "all vaults") as HTMLInputElement;
			// Nothing checked yet: neither checked nor mixed.
			expect(allWrite).not.toBeChecked();
			expect(allWrite).not.toBePartiallyChecked();
			expect(allRead).not.toBePartiallyChecked();
			// Every vault at write, later vaults at none.
			setLevel("work", "write");
			setLevel("personal", "write");
			expect(allWrite).toBePartiallyChecked();
			expect(allRead).toBePartiallyChecked();
			fireEvent.click(allWrite);
			expect(allWrite).toBeChecked();

			setLevel("work", "read");
			expect(allWrite).toBePartiallyChecked();
			expect(allRead).toBeChecked();

			fireEvent.click(allWrite);
			expect(box("write", "work")).toBeChecked();
			expect(box("write", "personal")).toBeChecked();

			fireEvent.click(allRead);
			expect(box("read", "work")).not.toBeChecked();
			expect(box("read", "personal")).not.toBeChecked();
			expect(allRead).not.toBeChecked();
			expect(allRead).not.toBePartiallyChecked();
			expect(box("read", "vaults you create later")).not.toBeChecked();
		});

		it("Write all sets later vaults to write; clearing Read all sets them to none", async () => {
			mcp();
			renderAt(VALID_QS);
			await choosePerVault();
			fireEvent.click(box("write", "all vaults") as HTMLInputElement);
			expect(box("write", "vaults you create later")).toBeChecked();
			expect(box("read", "vaults you create later")).toBeChecked();
			fireEvent.click(box("read", "all vaults") as HTMLInputElement);
			expect(box("read", "vaults you create later")).not.toBeChecked();
			expect(box("write", "vaults you create later")).not.toBeChecked();
		});

		it("the All row: Write checks Read; unchecking Read unchecks Write", async () => {
			mcp();
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			fireEvent.click(box("read", ALL) as HTMLInputElement);
			expect(box("read", ALL)).not.toBeChecked();
			expect(box("write", ALL)).not.toBeChecked();

			fireEvent.click(box("write", ALL) as HTMLInputElement);
			expect(box("write", ALL)).toBeChecked();
			expect(box("read", ALL)).toBeChecked();

			fireEvent.click(box("write", ALL) as HTMLInputElement);
			expect(box("write", ALL)).not.toBeChecked();
			expect(box("read", ALL)).toBeChecked();
		});

		it("disables Review with a reason when the All row reaches nothing", async () => {
			mcp();
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			fireEvent.click(box("read", ALL) as HTMLInputElement);
			const review = screen.getByRole("button", { name: /^review$/iu });
			expect(review).toBeDisabled();
			expect(review).toHaveAccessibleDescription(/choose at least one vault/iu);
			fireEvent.click(box("read", ALL) as HTMLInputElement);
			expect(review).toBeEnabled();
		});

		it("disables Review with a reason when no vault is reached", async () => {
			mcp();
			renderAt(VALID_QS);
			await choosePerVault();
			setLevel("work", "write");
			setLevel("personal", "write");
			setLevel("work", "none");
			expect(screen.getByRole("button", { name: /^review$/iu })).toBeEnabled();
			setLevel("personal", "none");
			const review = screen.getByRole("button", { name: /^review$/iu });
			expect(review).toBeDisabled();
			expect(review).toHaveAccessibleDescription(/choose at least one vault/iu);
			// A later-vaults policy alone is a reach, as in the key dialog.
			setLevel("vaults you create later", "read");
			expect(review).toBeEnabled();
		});
	});

	describe("a vault list long enough to need searching", () => {
		function mcp21() {
			vaultsState.current = manyVaults(21);
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
		}

		it("keeps later vaults outside the scroll area, before it, and holds only vault rows there", async () => {
			mcp21();
			renderAt(VALID_QS);
			await choosePerVault();
			const list = screen.getByRole("region", { name: /^vaults$/iu });
			const later = screen
				.getAllByRole("listitem")
				.find((li) => /vaults you create later/iu.test(li.textContent ?? ""));
			expect(later).toBeDefined();
			expect(list.contains(later!)).toBe(false);
			// The later row comes first, directly under the header.
			expect(screen.getAllByRole("listitem")[0]).toBe(later);
			expect(within(list).getAllByRole("listitem")).toHaveLength(21);
		});

		// jsdom cannot measure, so this pins the structure that makes the card
		// fit the screen by construction: flex columns down to a list that is
		// the only thing allowed to shrink, inside a card that may scroll, in a
		// panel never taller than the shell.
		it("fits the screen by construction: only the vault list shrinks", async () => {
			mcp21();
			renderAt(VALID_QS);
			await choosePerVault();
			const list = screen.getByRole("region", { name: /^vaults$/iu });
			const root = list.closest("[data-slot='scroll-area']") as HTMLElement;
			expect(root).toHaveClass("min-h-0", "flex-1");
			// About three rows at least (header, policy, three vaults), then the card scrolls.
			expect(root.parentElement).toHaveClass("flex", "flex-col", "flex-1", "min-h-[17rem]");
			const card = root.parentElement!.parentElement!;
			expect(card).toHaveClass("flex", "flex-col", "min-h-0", "overflow-y-auto");
			expect(card.parentElement).toHaveClass("flex", "flex-col", "max-h-full", "min-h-0");
		});

		it("never hides the later row while searching", async () => {
			mcp21();
			renderAt(VALID_QS);
			await choosePerVault();
			fireEvent.change(screen.getByRole("searchbox", { name: /Search vaults/iu }), {
				target: { value: "zzzz" },
			});
			const list = screen.getByRole("region", { name: /^vaults$/iu });
			expect(within(list).queryAllByRole("listitem")).toHaveLength(0);
			expect(screen.getAllByRole("listitem")[0]).toHaveTextContent(/vaults you create later/iu);
		});

		// The header row is the select-all row: it names what it acts on.
		it("labels the header row All vaults, then Matching vaults while filtering", async () => {
			mcp21();
			renderAt(VALID_QS);
			await choosePerVault();
			const header = document.querySelector("[data-slot='vault-header']") as HTMLElement;
			expect(header).toHaveTextContent(/^All vaults$/u);
			const field = screen.getByRole("searchbox", { name: /Search vaults/iu });
			expect(field).not.toHaveFocus();
			fireEvent.change(field, { target: { value: "Project 1" } });
			expect(header).toHaveTextContent(/^Matching vaults$/u);

			fireEvent.keyDown(field, { key: "Escape" });
			// Escape empties the filter; the field stays.
			expect(field).toHaveValue("");
			expect(header).toHaveTextContent(/^All vaults$/u);
			expect(box("read", "Personal")).toBeInTheDocument();
		});

		it("the clear button resets the filter and keeps the field", async () => {
			mcp21();
			renderAt(VALID_QS);
			await choosePerVault();
			fireEvent.change(screen.getByRole("searchbox", { name: /Search vaults/iu }), {
				target: { value: "Project 1" },
			});
			expect(box("read", "Personal")).toBeNull();
			fireEvent.click(screen.getByRole("button", { name: /^clear$/iu }));
			expect(screen.getByRole("searchbox", { name: /Search vaults/iu })).toHaveValue("");
			expect(screen.queryByRole("button", { name: /^clear$/iu })).toBeNull();
			expect(box("read", "Personal")).toBeInTheDocument();
		});

		function manyVaults(n: number) {
			return Array.from({ length: n }, (_, i) => ({
				id: `${String(i).padStart(8, "0")}-0000-0000-0000-000000000000`,
				name: i === 0 ? "Personal" : `Project ${i}`,
				is_default: i === 0,
				note_count: 0,
				attachment_count: 0,
			}));
		}

		// Above the threshold the field is there without a click.
		it("shows the field once the list is long enough to need it", async () => {
			vaultsState.current = manyVaults(12);
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
			renderAt(VALID_QS);

			await choosePerVault();
			expect(box("read", "Personal")).toBeInTheDocument();
			expect(screen.getByRole("searchbox", { name: /Search vaults/iu })).toBeInTheDocument();
		});

		it("stays out of the way while every vault fits on screen", async () => {
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
			renderAt(VALID_QS);

			await choosePerVault();
			expect(box("read", "Personal")).toBeInTheDocument();
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
			consentRedirectsTo("https://client.example/cb?code=x");
			renderAt(VALID_QS);

			// Drop one vault, so the grant is an explicit 11-of-12 set.
			await choosePerVaultAllWrite();
			setLevel("Project 5", "none");

			// The count rides with the filter: it exists to account for
			// selections the filter has hidden, so it has no job before then.
			expect(screen.queryByText("11 of 12 selected")).toBeNull();

			const search = screen.getByRole("searchbox", { name: /Search vaults/iu });
			fireEvent.change(search, { target: { value: "Project 1" } });

			// Project 1, 10, 11 match; Personal and Project 5 are hidden.
			expect(box("read", "Personal")).toBeNull();
			expect(box("read", "Project 5")).toBeNull();
			expect(box("read", "Project 10")).toBeInTheDocument();
			// Filtering narrows the vault rows only.
			expect(box("read", "vaults you create later")).toBeInTheDocument();
			expect(box("read", "shown vaults")).toBeInTheDocument();
			// Hiding a row must not deselect it — the count is unmoved.
			expect(screen.getByText("11 of 12 selected")).toBeInTheDocument();

			approve();
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

			await choosePerVault();
			const search = screen.getByRole("searchbox", { name: /Search vaults/iu });
			fireEvent.change(search, { target: { value: "zzzz" } });

			expect(screen.getByText(/No vaults match/)).toBeInTheDocument();
			// It sits outside the filtered list on purpose.
			expect(screen.getByRole("radio", { name: /^All vaults$/iu })).toBeInTheDocument();
			expect(box("read", "vaults you create later")).toBeInTheDocument();
		});

		// A permission picker must not change rows the user cannot see: under a
		// filter, select-all acts on the shown rows and says so.
		it("select-all acts on the shown rows while a filter is active", async () => {
			vaultsState.current = manyVaults(12);
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
			consentRedirectsTo("https://client.example/cb?code=x");
			vi.spyOn(window.location, "assign").mockImplementation(() => {});
			renderAt(VALID_QS);
			await choosePerVaultAllWrite();
			fireEvent.change(screen.getByRole("searchbox", { name: /Search vaults/iu }), {
				target: { value: "Project 1" },
			});
			// Project 1, 10 and 11 are shown; the header boxes name them.
			expect(box("write", "all vaults")).toBeNull();
			// Later vaults are always shown, so they are in scope too.
			fireEvent.click(box("write", "shown vaults") as HTMLInputElement);
			expect(box("write", "vaults you create later")).toBeChecked();
			fireEvent.click(box("write", "shown vaults") as HTMLInputElement);
			expect(box("write", "vaults you create later")).not.toBeChecked();
			expect(box("write", "Project 1")).not.toBeChecked();
			expect(box("read", "Project 1")).toBeChecked();
			fireEvent.click(box("read", "shown vaults") as HTMLInputElement);
			expect(screen.getByText("9 of 12 selected")).toBeInTheDocument();
			fireEvent.click(box("read", "shown vaults") as HTMLInputElement);
			expect(screen.getByText("12 of 12 selected")).toBeInTheDocument();
			fireEvent.click(box("read", "shown vaults") as HTMLInputElement);
			approve();
			await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
			// The nine hidden vaults kept Write; the three shown are off.
			const shown = /^Project 1/u;
			expect(postOAuthConsent.mock.calls[0]![0].vault_access).toEqual(
				Object.fromEntries(
					vaultsState.current.filter((v) => !shown.test(v.name)).map((v) => [v.id, "write"]),
				),
			);
		});

		it("select-all acts on every vault again once the filter is cleared", async () => {
			vaultsState.current = manyVaults(12);
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
			renderAt(VALID_QS);
			await choosePerVault();
			// Nothing starts checked: the first click fills, the second clears.
			fireEvent.click(box("read", "all vaults") as HTMLInputElement);
			fireEvent.click(box("read", "all vaults") as HTMLInputElement);
			expect(box("read", "Personal")).not.toBeChecked();
			expect(box("read", "Project 11")).not.toBeChecked();
		});
	});

	it("shows counts and the default badge", async () => {
		fetchOAuthClient.mockResolvedValue({
			client_id: "cli",
			client_name: "Claude Desktop",
			kind: "mcp",
		});
		renderAt(VALID_QS);
		await choosePerVault();
		expect(screen.getByText("1,204 notes · 18 files")).toBeInTheDocument();
		// A narrow German screen broke "Standard" mid-word: the badge never wraps.
		expect(screen.getByText("default")).toHaveClass("whitespace-nowrap");
	});

	// Consent asks twice: pick, then a plain-language summary to approve.
	describe("review step", () => {
		function mcp() {
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Claude Desktop",
				kind: "mcp",
			});
		}

		function review() {
			fireEvent.click(screen.getByRole("button", { name: /^review$/iu }));
			return screen.getByRole("region", { name: /will be able to/iu });
		}

		// Each group is a level heading over its chips, in display order.
		function groups(region: HTMLElement): [string, string[]][] {
			return within(region)
				.getAllByRole("heading", { level: 3 })
				.map((h) => [
					h.textContent ?? "",
					within(h.closest("li") as HTMLElement)
						.getAllByRole("listitem")
						.map((li) => li.textContent ?? ""),
				]);
		}

		it("collapses All vaults to one line", async () => {
			mcp();
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			const region = review();
			expect(within(region).getByRole("heading", { level: 2 })).toHaveTextContent(
				"Claude Desktop will be able to:",
			);
			expect(groups(region)).toEqual([
				["Can read and change notes", ["All vaults, including ones you create later"]],
			]);
			expect(region).toHaveTextContent(
				"You can change or revoke this anytime in Settings > Connections.",
			);
		});

		it("names the connection by its label when one was typed", async () => {
			mcp();
			renderAt(VALID_QS);
			fireEvent.change(await screen.findByLabelText(/Name this connection/), {
				target: { value: "Laptop agent" },
			});
			expect(within(review()).getByRole("heading", { level: 2 })).toHaveTextContent(
				"Laptop agent will be able to:",
			);
		});

		it("says what Read only rules out", async () => {
			mcp();
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			allReadOnly();
			const region = review();
			expect(groups(region)).toEqual([
				["Can read notes", ["All vaults, including ones you create later"]],
			]);
			expect(region).toHaveTextContent("Cannot change, create or delete notes");
		});

		it("groups chosen vaults by level, then later vaults", async () => {
			vaultsState.current = [
				...DEFAULT_VAULTS,
				{
					id: "33333333-3333-3333-3333-333333333333",
					name: "Journal",
					is_default: false,
					note_count: 3,
					attachment_count: 0,
				},
			];
			mcp();
			renderAt(VALID_QS);
			await choosePerVault();
			setLevel("work", "write");
			setLevel("journal", "read");
			setLevel("vaults you create later", "read");
			expect(groups(review())).toEqual([
				["Can read and change notes", ["Work"]],
				["Can read notes", ["Journal", "Vaults you create later"]],
				["No access", ["Personal"]],
			]);
		});

		// Every current vault at one level reads as one chip; later vaults keep
		// their own group when their level differs.
		it("says No access for later vaults by default", async () => {
			mcp();
			renderAt(VALID_QS);
			await choosePerVaultAllWrite();
			const region = review();
			expect(groups(region)).toEqual([
				["Can read and change notes", ["All current vaults"]],
				["No access", ["Vaults you create later"]],
			]);
			expect(region).not.toHaveTextContent("Cannot change, create or delete notes");
		});

		it("collapses every vault plus later vaults at one level to one chip", async () => {
			mcp();
			renderAt(VALID_QS);
			await choosePerVaultAllWrite();
			setLevel("vaults you create later", "write");
			expect(groups(review())).toEqual([
				["Can read and change notes", ["All vaults, including ones you create later"]],
			]);
		});

		it("a long list shows every vault, with no folding", async () => {
			vaultsState.current = Array.from({ length: 12 }, (_, i) => ({
				id: `${String(i).padStart(8, "0")}-0000-0000-0000-000000000000`,
				name: i === 0 ? "Personal" : `Project ${i}`,
				is_default: i === 0,
				note_count: 0,
				attachment_count: 0,
			}));
			mcp();
			renderAt(VALID_QS);
			await choosePerVaultAllWrite();
			setLevel("personal", "read");
			const region = review();
			expect(groups(region)).toEqual([
				["Can read and change notes", Array.from({ length: 11 }, (_, i) => `Project ${i + 1}`)],
				["Can read notes", ["Personal"]],
				["No access", ["Vaults you create later"]],
			]);
			expect(within(region).queryByRole("button", { name: /more$/u })).toBeNull();
		});

		it("Back returns to the picker with every choice kept", async () => {
			mcp();
			renderAt(VALID_QS);
			await choosePerVaultAllWrite();
			setLevel("work", "read");
			review();
			fireEvent.click(screen.getByRole("button", { name: /^back$/iu }));
			expect(screen.getByRole("radio", { name: /^choose vaults$/iu })).toBeChecked();
			expect(box("read", "work")).toBeChecked();
			expect(box("write", "work")).not.toBeChecked();
			expect(box("write", "personal")).toBeChecked();
		});

		// StrictMode runs effects twice on mount; a "first run" flag is spent by
		// the first pass and the second stole focus to the h1 on load in dev.
		it("leaves focus alone on load under StrictMode", async () => {
			mcp();
			const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
			render(
				<StrictMode>
					<QueryClientProvider client={qc}>
						<MemoryRouter initialEntries={[`/oauth/consent${VALID_QS}`]}>
							<OAuthAuthorizePage />
						</MemoryRouter>
					</QueryClientProvider>
				</StrictMode>,
			);
			await screen.findByRole("button", { name: /^review$/iu });
			expect(screen.getByRole("heading", { level: 1 })).not.toHaveFocus();
		});

		it("moves focus to the summary heading, and back to the picker on Back", async () => {
			mcp();
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			const region = review();
			expect(within(region).getByRole("heading", { level: 2 })).toHaveFocus();
			fireEvent.click(screen.getByRole("button", { name: /^back$/iu }));
			expect(screen.getByRole("heading", { level: 1 })).toHaveFocus();
		});
	});

	// Meta Muse's directory requires a Read Only option on OAuth connectors
	// (#174). The choice can only narrow: a client that asked for mcp:read
	// cannot be widened from here.
	describe("read-only option", () => {
		const READ_QS = VALID_QS.replace("scope=vault.read", "scope=mcp:read");

		function approveIt() {
			consentRedirectsTo("https://app/cb?code=ok");
			vi.spyOn(window.location, "assign").mockImplementation(() => {});
			approve();
		}

		it("starts at Write and sends no read_only flag", async () => {
			fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Muse", kind: "mcp" });
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			expect(box("write", ALL)).toBeChecked();
			approveIt();
			await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
			expect(postOAuthConsent.mock.lastCall?.[0]).not.toHaveProperty("read_only");
		});

		it("downgrades the grant when All vaults loses Write", async () => {
			fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Muse", kind: "mcp" });
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			allReadOnly();
			approveIt();
			await waitFor(() =>
				expect(postOAuthConsent).toHaveBeenCalledWith(expect.objectContaining({ read_only: true })),
			);
		});

		it("offers no Write when the client itself asked for mcp:read", async () => {
			fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Muse", kind: "mcp" });
			renderAt(READ_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			expect(box("read", ALL)).toBeChecked();
			expect(box("write", ALL)).toBeNull();
			approveIt();
			await waitFor(() =>
				expect(postOAuthConsent).toHaveBeenCalledWith(
					expect.objectContaining({ scope: "mcp:read", read_only: true }),
				),
			);
		});

		it("is not offered to an Obsidian device client", async () => {
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Obsidian",
				kind: "obsidian",
			});
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			expect(box("write", ALL)).toBeNull();
		});

		// No Write anywhere is a read-only connection, so the AI sees no write
		// tools, matching the pick.
		it("is requested when Choose vaults grants no Write anywhere", async () => {
			fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Muse", kind: "mcp" });
			renderAt(VALID_QS);
			await choosePerVault();
			setLevel("work", "read");
			setLevel("personal", "read");
			approveIt();
			await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
			const body = postOAuthConsent.mock.lastCall?.[0];
			expect(body?.vault_access).toEqual({
				"11111111-1111-1111-1111-111111111111": "read",
				"22222222-2222-2222-2222-222222222222": "read",
			});
			expect(body).toMatchObject({ default_access: "none", read_only: true });
			expect(JSON.stringify(body)).not.toContain('"write"');
		});
	});

	// Per-vault access levels (#174): each vault reached is Read or Read and
	// write, "All vaults" carries one level for every vault including later
	// ones, and a picked set has its own "Vaults you create later" policy.
	describe("access levels", () => {
		const PERSONAL = "11111111-1111-1111-1111-111111111111";
		const WORK = "22222222-2222-2222-2222-222222222222";
		const READ_QS = VALID_QS.replace("scope=vault.read", "scope=mcp:read");

		function approveAndGetBody() {
			consentRedirectsTo("https://app/cb?code=ok");
			vi.spyOn(window.location, "assign").mockImplementation(() => {});
			approve();
			return waitFor(() => {
				expect(postOAuthConsent).toHaveBeenCalled();
				return postOAuthConsent.mock.lastCall?.[0];
			});
		}

		function mcpClient() {
			fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Muse", kind: "mcp" });
		}

		it("all vaults defaults to read and write, for later vaults too", async () => {
			mcpClient();
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			const body = await approveAndGetBody();
			expect(body).toMatchObject({ default_access: "write" });
			expect(body).not.toHaveProperty("vault_access");
		});

		// All vaults without Write is every vault at read, later ones too, and
		// the consent also carries read_only (mcp:read), as the old switch did.
		it("all vaults can be read only", async () => {
			mcpClient();
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			allReadOnly();
			expect(await approveAndGetBody()).toMatchObject({ default_access: "read", read_only: true });
		});

		it("picked vaults send a level each; later vaults none by default", async () => {
			mcpClient();
			renderAt(VALID_QS);
			await choosePerVault();
			setLevel("personal", "none");
			setLevel("work", "read");
			const body = await approveAndGetBody();
			// With a "none" policy an unpicked vault says nothing the policy does
			// not, and every entry rides in the access token: it is not sent.
			expect(body?.vault_access).toEqual({ [WORK]: "read" });
			expect(body?.default_access).toBe("none");
		});

		it("explains and sets the policy for vaults created later", async () => {
			mcpClient();
			renderAt(VALID_QS);
			await choosePerVault();
			setLevel("work", "write");
			expect(box("read", "vaults you create later")).not.toBeChecked();
			setLevel("vaults you create later", "read");
			const body = await approveAndGetBody();
			expect(body).toMatchObject({ default_access: "read" });
			// Work keeps Write, so the grant is not read-only.
			expect(body).not.toHaveProperty("read_only");
			// A non-none policy WOULD reach the unpicked vault, so it is sent as none.
			expect(body?.vault_access).toEqual({ [PERSONAL]: "none", [WORK]: "write" });
		});

		// A vault that appears after Choose vaults was picked (a refetch) was
		// never seen by the user, so it gets the later-vaults policy, not the
		// level select-all gave the vaults on screen.
		it("a vault that appears mid-flow takes the later-vaults level", async () => {
			mcpClient();
			renderAt(VALID_QS);
			await choosePerVaultAllWrite();
			vaultsState.current = [
				...DEFAULT_VAULTS,
				{
					id: "33333333-3333-3333-3333-333333333333",
					name: "Journal",
					is_default: false,
					note_count: 0,
					attachment_count: 0,
				},
			];
			// Any state change re-renders with the refetched list.
			fireEvent.change(screen.getByLabelText(/Name this connection/), {
				target: { value: "x" },
			});
			expect(box("read", "journal")).not.toBeChecked();
			expect(box("write", "work")).toBeChecked();
			const body = await approveAndGetBody();
			expect(body?.vault_ids).toEqual([PERSONAL, WORK]);
			expect(body?.vault_access).toEqual({ [PERSONAL]: "write", [WORK]: "write" });
		});

		// The header and the later-vaults policy stay on screen; only the vault
		// rows scroll, so a long list never pushes the policy or the buttons away.
		it("pins later vaults above a scrolling list of vault rows", async () => {
			mcpClient();
			renderAt(VALID_QS);
			await choosePerVault();
			const items = screen.getAllByRole("listitem");
			expect(items[0]).toHaveTextContent(/vaults you create later/iu);
			const list = screen.getByRole("region", { name: /^vaults$/iu });
			expect(
				within(list)
					.getAllByRole("listitem")
					.map((r) => r.textContent),
			).toEqual([expect.stringMatching(/^Personal/u), expect.stringMatching(/^Work/u)]);
		});

		it("a client that asked for mcp:read cannot be given write anywhere", async () => {
			mcpClient();
			renderAt(READ_QS);
			await choosePerVault();
			setLevel("work", "read");
			// No Write box on any row, header or policy.
			expect(screen.queryAllByRole("checkbox", { name: /^write:/iu })).toEqual([]);
			const body = await approveAndGetBody();
			expect(body.vault_access).toEqual({ [WORK]: "read" });
			expect(body).toMatchObject({ default_access: "none" });
			expect(JSON.stringify(body)).not.toContain('"write"');
		});

		it("an Obsidian device client gets no level controls", async () => {
			fetchOAuthClient.mockResolvedValue({
				client_id: "cli",
				client_name: "Obsidian",
				kind: "obsidian",
			});
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			expect(box("write", ALL)).toBeNull();
			await choosePerVault();
			// A device is in or out: one box per vault, no Read/Write split, no
			// policy for later vaults.
			fireEvent.click(screen.getByRole("checkbox", { name: /personal/iu }));
			expect(box("read", "work")).toBeNull();
			expect(box("write", "work")).toBeNull();
			expect(screen.queryByRole("checkbox", { name: /create later/iu })).not.toBeInTheDocument();
		});
	});

	// A backend that predates levels ignores read_only/vault_access and mints
	// FULL access, so the screen must not offer what it cannot deliver.
	describe("a backend without access levels", () => {
		it("offers no Read only box or level pickers, and sends neither", async () => {
			accessLevelsState.current = false;
			fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Muse", kind: "mcp" });
			postOAuthConsent.mockResolvedValue({ redirect_uri: "https://app/cb?code=ok" });
			const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
			renderAt(VALID_QS);
			await choosePerVault();
			fireEvent.click(screen.getByRole("checkbox", { name: /work/iu }));
			expect(box("read", "work")).toBeNull();
			expect(screen.queryByRole("checkbox", { name: /create later/iu })).not.toBeInTheDocument();
			approve();
			await waitFor(() => expect(assign).toHaveBeenCalledWith("https://app/cb?code=ok"));
			const body = postOAuthConsent.mock.lastCall?.[0];
			expect(body).not.toHaveProperty("read_only");
			expect(body).not.toHaveProperty("vault_access");
			expect(body).not.toHaveProperty("default_access");
			expect(body?.vault_ids).toEqual(["22222222-2222-2222-2222-222222222222"]);
		});
	});

	// The backend echoes what it stored. A missing or wider echo means the
	// grant is not what the user picked: never hand that code to the client.
	describe("granted echo", () => {
		function mcpRead() {
			fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Muse", kind: "mcp" });
			renderAt(VALID_QS);
		}

		async function approveWith(response: object) {
			postOAuthConsent.mockResolvedValue(response);
			const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
			await screen.findByRole("button", { name: /^review$/iu });
			allReadOnly();
			approve();
			await waitFor(() => expect(postOAuthConsent).toHaveBeenCalled());
			return assign;
		}

		it("does not redirect when the echo is missing", async () => {
			mcpRead();
			const assign = await approveWith({ redirect_uri: "https://app/cb?code=ok" });
			expect(await screen.findByRole("alert")).toHaveTextContent(/more access than you chose/iu);
			expect(assign).not.toHaveBeenCalled();
		});

		it("does not redirect when the echo is wider than the pick", async () => {
			mcpRead();
			const assign = await approveWith({
				redirect_uri: "https://app/cb?code=ok",
				granted: { scope: "mcp", vault_access: {}, default_access: "write" },
			});
			expect(await screen.findByRole("alert")).toHaveTextContent(/more access than you chose/iu);
			expect(assign).not.toHaveBeenCalled();
		});

		it("does not redirect when Read only was asked for and a write scope came back", async () => {
			fetchOAuthClient.mockResolvedValue({ client_id: "cli", client_name: "Muse", kind: "mcp" });
			renderAt(VALID_QS);
			await screen.findByRole("button", { name: /^review$/iu });
			allReadOnly();
			postOAuthConsent.mockResolvedValue({
				redirect_uri: "https://app/cb?code=ok",
				granted: { scope: "mcp", vault_access: {}, default_access: "read" },
			});
			const assign = vi.spyOn(window.location, "assign").mockImplementation(() => {});
			approve();
			expect(await screen.findByRole("alert")).toHaveTextContent(/more access than you chose/iu);
			expect(assign).not.toHaveBeenCalled();
		});

		it("redirects when the echo matches", async () => {
			mcpRead();
			const assign = await approveWith({
				redirect_uri: "https://app/cb?code=ok",
				granted: { scope: "mcp:read", vault_access: {}, default_access: "read" },
			});
			await waitFor(() => expect(assign).toHaveBeenCalledWith("https://app/cb?code=ok"));
		});

		it("still follows a refusal redirect, which grants nothing", async () => {
			mcpRead();
			const assign = await approveWith({
				redirect_uri: "https://app/cb?error=access_denied&state=s",
			});
			await waitFor(() =>
				expect(assign).toHaveBeenCalledWith("https://app/cb?error=access_denied&state=s"),
			);
		});
	});
});

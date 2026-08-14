import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import DeviceLinkPage from "./device-link-page";

const { get, post } = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }));
vi.mock("../api/client", () => ({ api: { get, post } }));

const { setActiveVaultId } = vi.hoisted(() => ({ setActiveVaultId: vi.fn() }));
vi.mock("../api/active-vault", () => ({ setActiveVaultId }));

const authState = vi.hoisted(() => ({ current: { isSignedIn: true } as { isSignedIn: boolean } }));
// useAuthAdapter must expose getToken: DeviceLinkPage mounts useVaultReadyEvents,
// whose effect calls `await getToken()`. Without it the fire-and-forget connect()
// rejects with "getToken is not a function" (an unhandled rejection that fails the
// run even though assertions pass). Returning null makes connect() early-return —
// no socket opened in the unit test. Spread authState last so per-test isSignedIn
// still applies.
vi.mock("../auth/use-auth-adapter", () => ({
	useAuthAdapter: () => ({ getToken: () => Promise.resolve(null), ...authState.current }),
}));

vi.mock("../theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

// The /link page now reads /billing/status to drive the proactive cap UI.
// Default: unlimited (atCap=false) so existing tests still see the normal flow.
interface FakeBilling {
	caps: {
		obsidian_connections: number | null;
		mcp_connections: number | null;
		api_write_enabled: boolean;
	};
	current_connections: { obsidian: number; mcp: number };
	device_swap_cooldown_remaining_hours: number | null;
}
const billingState = vi.hoisted(() => ({
	current: {
		caps: { obsidian_connections: null, mcp_connections: null, api_write_enabled: true },
		current_connections: { obsidian: 0, mcp: 0 },
		device_swap_cooldown_remaining_hours: null,
	} as FakeBilling,
}));
vi.mock("../api/queries", async (importOriginal) => {
	const actual = await importOriginal<typeof import("../api/queries")>();
	return {
		...actual,
		useBillingStatus: () => ({ data: billingState.current }),
		useMe: () => ({ data: { id: 1, email: "me@example.com" } }),
		// The cap panel reads this — keep it deterministic across tests so we
		// don't trigger real network fetches via the partial-mock pass-through.
		useConnections: () => ({
			data: [
				{
					kind: "obsidian",
					client_id: null,
					key_id: 42,
					name: "Old laptop",
					software_id: null,
					software_version: null,
					verified: false,
					logo: null,
					vault_id: 1,
					vault_name: "Personal",
					scope: null,
					last_used_at: null,
					connected_at: null,
					first_user_agent: null,
					first_ip: null,
					redirect_uri: null,
					redirect_uris: [],
					cimd_url: null,
				},
			],
			isLoading: false,
		}),
	};
});

function renderPage() {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter>
				<DeviceLinkPage />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

afterEach(() => {
	vi.clearAllMocks();
	window.history.replaceState({}, "", "/link");
	authState.current = { isSignedIn: true };
	billingState.current = {
		caps: { obsidian_connections: null, mcp_connections: null, api_write_enabled: true },
		current_connections: { obsidian: 0, mcp: 0 },
		device_swap_cooldown_remaining_hours: null,
	};
});

describe("DeviceLinkPage", () => {
	it("shows a sign-in prompt when signed out", () => {
		authState.current = { isSignedIn: false };
		renderPage();
		expect(screen.getByText(/sign in to link/iu)).toBeInTheDocument();
	});

	// The code field is the only thing to do on this step — you shouldn't have to
	// click into it before typing the code you came here to type.
	it("focuses the code field on arrival", () => {
		renderPage();
		expect(screen.getByPlaceholderText(/XXXX-XXXX/iu)).toHaveFocus();
	});

	// RFC 8628 verification_uri_complete. The plugin opens /link?code=ENGR-7X4K,
	// so the user never retypes what their own machine already knows.
	it("auto-verifies a code supplied in the query string", async () => {
		window.history.replaceState({}, "", "/link?code=ENGR-7X4K");
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 12 }] });
		renderPage();

		await waitFor(() => expect(get).toHaveBeenCalledWith("/vaults?user_code=ENGR-7X4K"));
		expect(await screen.findByRole("radio", { name: /personal/iu })).toBeInTheDocument();
	});

	// Authorizing is still an explicit act: auto-verify only lists the vaults.
	// Nothing is linked until the user picks one and clicks Sync.
	it("does not authorize on its own after auto-verifying", async () => {
		window.history.replaceState({}, "", "/link?code=ENGR-7X4K");
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 12 }] });
		renderPage();

		await screen.findByRole("radio", { name: /personal/iu });
		expect(post).not.toHaveBeenCalled();
	});

	// A single-use code shouldn't linger in history, bookmarks, or a shared URL.
	it("scrubs the code out of the URL once it has been read", async () => {
		window.history.replaceState({}, "", "/link?code=ENGR-7X4K");
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 12 }] });
		renderPage();

		await waitFor(() => expect(window.location.search).toBe(""));
		expect(window.location.pathname).toBe("/link");
	});

	it("does not auto-verify when no code was supplied", () => {
		renderPage();
		expect(get).not.toHaveBeenCalled();
	});

	// The backend answers 200 with the user's vault list regardless of whether
	// the code is real — `user_code_valid` is the only signal. Before this,
	// every 8-character string sailed through to the picker and only failed at
	// authorize, three clicks later.
	it("rejects a typed code the backend reports as invalid", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 12 }],
			user_code_valid: false,
		});
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ZZZZZZZZ" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		expect(await screen.findByRole("alert")).toHaveTextContent(/invalid or has expired/iu);
		expect(screen.queryByRole("radio", { name: /personal/iu })).not.toBeInTheDocument();
		expect(screen.getByPlaceholderText(/XXXX-XXXX/iu)).toBeInTheDocument();
	});

	it("rejects an invalid code that arrived in the query string", async () => {
		window.history.replaceState({}, "", "/link?code=ZZZZ-ZZZZ");
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 12 }],
			user_code_valid: false,
		});
		renderPage();

		expect(await screen.findByRole("alert")).toHaveTextContent(/invalid or has expired/iu);
		expect(screen.queryByRole("radio", { name: /personal/iu })).not.toBeInTheDocument();
	});

	// A valid code whose plugin sent no vault-name hint reports
	// suggested_vault_name: null. That must NOT read as invalid.
	it("accepts a valid code that has no suggested vault name", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 12 }],
			suggested_vault_name: null,
			user_code_valid: true,
		});
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		expect(await screen.findByRole("radio", { name: /personal/iu })).toBeInTheDocument();
	});

	// Forward compatibility: a frontend deployed ahead of the backend sees no
	// `user_code_valid` at all. Rejecting on undefined would break every link.
	it("proceeds when the backend omits user_code_valid entirely", async () => {
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 12 }] });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		expect(await screen.findByRole("radio", { name: /personal/iu })).toBeInTheDocument();
	});

	it("rejects a code that is not 8 characters", () => {
		renderPage();
		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ABC" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		expect(screen.getByRole("alert")).toHaveTextContent(/8 characters/iu);
		expect(get).not.toHaveBeenCalled();
	});

	it("verifies a valid code and authorizes the chosen vault", async () => {
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 12 }] });
		post.mockResolvedValue({ ok: true, vault_id: 7 });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		fireEvent.click(await screen.findByRole("radio", { name: /personal/iu }));
		fireEvent.click(screen.getByRole("button", { name: /^sync$/iu }));

		await waitFor(() =>
			expect(post).toHaveBeenCalledWith(
				"/auth/device/authorize",
				expect.objectContaining({ user_code: "ENGR-7X4K", vault_id: 7 }),
			),
		);
		expect(await screen.findByText(/your vault is linked/iu)).toBeInTheDocument();
	});

	// The heading used to stay "Link Obsidian Vault" on the success step — a
	// title for a job already finished. It should name the step you're on.
	it("retitles the page for each step", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 12 }],
			user_code_valid: true,
		});
		post.mockResolvedValue({ ok: true, vault_id: 7 });
		renderPage();
		expect(screen.getByRole("heading", { name: /link obsidian vault/iu })).toBeInTheDocument();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		expect(
			await screen.findByRole("heading", { name: /choose a vault to sync/iu }),
		).toBeInTheDocument();

		fireEvent.click(await screen.findByRole("radio", { name: /personal/iu }));
		fireEvent.click(screen.getByRole("button", { name: /^sync$/iu }));

		expect(
			await screen.findByRole("heading", { name: /finish in obsidian/iu }),
		).toBeInTheDocument();
		expect(
			screen.queryByRole("heading", { name: /link obsidian vault/iu }),
		).not.toBeInTheDocument();
	});

	it("lets you go to the vault without waiting for the first sync", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 12 }],
			user_code_valid: true,
		});
		post.mockResolvedValue({ ok: true, vault_id: 7 });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		fireEvent.click(await screen.findByRole("radio", { name: /personal/iu }));
		fireEvent.click(screen.getByRole("button", { name: /^sync$/iu }));

		expect(
			await screen.findByRole("button", { name: /go to my vault without waiting/iu }),
		).toBeInTheDocument();
	});

	// Obsidian registers the `obsidian://` URI scheme, so getting the user back
	// to their editor is a link, not an integration. The vault name is the one
	// the plugin sent at device-flow start — i.e. the LOCAL Obsidian vault name,
	// which is exactly what `obsidian://open?vault=` addresses.
	it("offers a deep link back to Obsidian once the vault is linked", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 12 }],
			suggested_vault_name: "My Local Notes",
			user_code_valid: true,
		});
		post.mockResolvedValue({ ok: true, vault_id: 7 });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		fireEvent.click(await screen.findByRole("radio", { name: /personal/iu }));
		fireEvent.click(screen.getByRole("button", { name: /^sync$/iu }));

		const link = await screen.findByRole("link", { name: /open obsidian/iu });
		expect(link).toHaveAttribute("href", "obsidian://open?vault=My%20Local%20Notes");
	});

	// No hint means we cannot address a vault, and `obsidian://open` without one
	// is not a thing. Hide the button rather than render a broken link.
	it("hides the Obsidian deep link when the plugin sent no vault name", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 12 }],
			user_code_valid: true,
		});
		post.mockResolvedValue({ ok: true, vault_id: 7 });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		fireEvent.click(await screen.findByRole("radio", { name: /personal/iu }));
		fireEvent.click(screen.getByRole("button", { name: /^sync$/iu }));

		expect(await screen.findByText(/your vault is linked/iu)).toBeInTheDocument();
		expect(screen.queryByRole("link", { name: /open obsidian/iu })).not.toBeInTheDocument();
	});

	it("forwards to the linked vault (sets it active) after authorizing", async () => {
		get.mockResolvedValue({
			vaults: [
				{ id: 7, name: "Personal", note_count: 12 },
				{ id: 9, name: "Work", note_count: 3 },
			],
		});
		post.mockResolvedValue({ ok: true, vault_id: 9 });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		fireEvent.click(await screen.findByRole("radio", { name: /work/iu }));
		fireEvent.click(screen.getByRole("button", { name: /^sync$/iu }));

		await waitFor(() => expect(setActiveVaultId).toHaveBeenCalledWith(9));
	});

	it("shows the heads-up banner (but keeps the code input) when at the Obsidian cap", () => {
		// Free-tier user already syncing one Obsidian device — landing on /link
		// shows a banner explaining the swap (this device will replace the existing
		// one), but the code input stays visible so they can still proceed.
		billingState.current = {
			caps: { obsidian_connections: 1, mcp_connections: 1, api_write_enabled: true },
			current_connections: { obsidian: 1, mcp: 0 },
			device_swap_cooldown_remaining_hours: null,
		};
		renderPage();
		expect(screen.getByRole("status")).toHaveTextContent(/heads up/iu);
		expect(screen.getByRole("status")).toHaveTextContent(/will disconnect/iu);
		expect(screen.getByPlaceholderText(/XXXX-XXXX/iu)).toBeInTheDocument();
	});

	it("shows a cooldown banner and disables Sync when atCap and a swap cooldown is active", async () => {
		// Free-tier user just swapped: they're at the obsidian cap AND inside the
		// 24h swap-cooldown window. The implicit-swap UX would disconnect the
		// existing device and then trip the 402 on authorize, leaving them at 0
		// connections — so we block the action and surface the wait time instead.
		billingState.current = {
			caps: { obsidian_connections: 1, mcp_connections: 1, api_write_enabled: true },
			current_connections: { obsidian: 1, mcp: 0 },
			device_swap_cooldown_remaining_hours: 17,
		};
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 12 }] });
		renderPage();

		const alert = screen.getByRole("alert");
		expect(alert).toHaveTextContent(/recently swapped devices/iu);
		expect(alert).toHaveTextContent(/swap again in 17h/iu);
		// The normal "linking will disconnect" heads-up should NOT render when the
		// cooldown banner is up.
		expect(screen.queryByRole("status")).not.toBeInTheDocument();

		// Walk through to the pick-vault step so the Sync button is on screen.
		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		const sync = await screen.findByRole("button", { name: /^sync$/iu });
		expect(sync).toBeDisabled();
	});
});

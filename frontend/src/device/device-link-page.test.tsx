import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter, useLocation } from "react-router";
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
const billingPending = vi.hoisted(() => ({ current: false }));
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
		useBillingStatus: () => ({
			data: billingPending.current ? undefined : billingState.current,
			isPending: billingPending.current,
		}),
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

// Renders the router's own location so a test can assert what the URL bar
// would show. The page scrubs through the router, and react-router's location
// is the only thing that reflects that — `window.location` is decoupled here.
function LocationProbe() {
	const { pathname, search } = useLocation();
	return <span data-testid="location">{`${pathname}${search}`}</span>;
}

function pageTree(entry: string, qc: QueryClient) {
	return (
		<QueryClientProvider client={qc}>
			<MemoryRouter initialEntries={[entry]}>
				<DeviceLinkPage />
				<LocationProbe />
			</MemoryRouter>
		</QueryClientProvider>
	);
}

function renderPage(entry = "/link") {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return { qc, ...render(pageTree(entry, qc)) };
}

afterEach(() => {
	vi.clearAllMocks();
	billingPending.current = false;
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
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
		renderPage("/link?code=ENGR-7X4K");

		await waitFor(() => expect(get).toHaveBeenCalledWith("/vaults?user_code=ENGR-7X4K"));
		expect(await screen.findByRole("radio", { name: /personal/iu })).toBeInTheDocument();
	});

	// Authorizing is still an explicit act: auto-verify only lists the vaults.
	// Nothing is linked until the user picks one and clicks Sync.
	it("does not authorize on its own after auto-verifying", async () => {
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
		renderPage("/link?code=ENGR-7X4K");

		await screen.findByRole("radio", { name: /personal/iu });
		expect(post).not.toHaveBeenCalled();
	});

	// A single-use code shouldn't linger in history, bookmarks, or a shared URL.
	//
	// Asserted on the ROUTER's location, which is what the address bar shows on
	// createBrowserRouter. The old version checked `window.location` under a
	// MemoryRouter — two decoupled things — so it passed no matter what the
	// page did, including when the code was still live in `useLocation()` and
	// being re-emitted into the billing links.
	it("scrubs the code out of the URL once it has been read", async () => {
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
		renderPage("/link?code=ENGR-7X4K");

		await waitFor(() => expect(screen.getByTestId("location")).toHaveTextContent("/link"));
		expect(screen.getByTestId("location").textContent).not.toContain("ENGR");
	});

	// Scrub the credential, not the whole query string: other params on this
	// URL belong to whoever put them there.
	it("leaves unrelated query params alone", async () => {
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
		renderPage("/link?code=ENGR-7X4K&ref=newsletter");

		await waitFor(() => expect(get).toHaveBeenCalled());
		const url = screen.getByTestId("location").textContent ?? "";
		expect(url).toContain("ref=newsletter");
		expect(url).not.toContain("code=");
	});

	// The default vault selection is cap-aware, and the cap arrives from
	// /billing/status. Typing a code takes longer than that fetch, so only the
	// auto path can outrun it — and when it did, an at-cap user was defaulted
	// onto a create-new row that renders disabled, with Sync still armed for a
	// guaranteed 402.
	it("waits for the vault cap before auto-verifying", async () => {
		billingPending.current = true;
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
		const { qc, rerender } = renderPage("/link?code=ENGR-7X4K");

		expect(get).not.toHaveBeenCalled();

		// Same mount, cap now known — the verify must resume on its own rather
		// than needing another visit.
		billingPending.current = false;
		rerender(pageTree("/link?code=ENGR-7X4K", qc));
		await waitFor(() => expect(get).toHaveBeenCalledWith("/vaults?user_code=ENGR-7X4K"));
	});

	// RFC 8628 §5.4: typing the code IS the anti-phishing beat, and arriving
	// with ?code= skips it. The suggested vault name comes from an
	// unauthenticated endpoint, so it is not evidence of who is asking.
	it("warns about the requesting device only when the code arrived in the URL", async () => {
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
		renderPage("/link?code=ENGR-7X4K");

		expect(
			await screen.findByText(/only continue if you started this from obsidian/iu),
		).toBeInTheDocument();
	});

	it("does not warn when the user typed the code themselves", async () => {
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));

		await screen.findByRole("radio", { name: /personal/iu });
		expect(screen.queryByText(/only continue if you started this/iu)).not.toBeInTheDocument();
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
			vaults: [{ id: 7, name: "Personal", note_count: 0 }],
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
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 0 }],
			user_code_valid: false,
		});
		renderPage("/link?code=ZZZZ-ZZZZ");

		expect(await screen.findByRole("alert")).toHaveTextContent(/invalid or has expired/iu);
		expect(screen.queryByRole("radio", { name: /personal/iu })).not.toBeInTheDocument();
	});

	// A valid code whose plugin sent no vault-name hint reports
	// suggested_vault_name: null. That must NOT read as invalid.
	it("accepts a valid code that has no suggested vault name", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 0 }],
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
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
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
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
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
			vaults: [{ id: 7, name: "Personal", note_count: 0 }],
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

	it("lets you continue to the web app without waiting for the first sync", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 0 }],
			user_code_valid: true,
		});
		post.mockResolvedValue({ ok: true, vault_id: 7 });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		fireEvent.click(await screen.findByRole("radio", { name: /personal/iu }));
		fireEvent.click(screen.getByRole("button", { name: /^sync$/iu }));

		expect(
			await screen.findByRole("button", { name: /continue to web app/iu }),
		).toBeInTheDocument();
	});

	// `vault_populated` fires when a vault goes from 0 to 1 notes. Link into a
	// vault that already has notes and it can never fire — so waiting on it is
	// waiting on nothing. The picker already knows note_count; use it.
	it("does not wait for a first sync when the linked vault already has notes", async () => {
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

		// The user still has to go back to Obsidian and finish the sync, so the
		// step MUST render. What can't happen is the waiting — `vault_populated`
		// is a 0->1 event and this vault is already past that.
		expect(
			await screen.findByRole("heading", { name: /finish in obsidian/iu }),
		).toBeInTheDocument();
		expect(screen.queryByText(/waiting for your first sync/iu)).not.toBeInTheDocument();
		expect(screen.queryByText(/the moment it lands/iu)).not.toBeInTheDocument();
	});

	// An empty vault genuinely can produce the event, so the wait is real there.
	it("waits for the first sync when the linked vault is empty", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 0 }],
			user_code_valid: true,
		});
		post.mockResolvedValue({ ok: true, vault_id: 7 });
		renderPage();

		fireEvent.change(screen.getByPlaceholderText(/XXXX-XXXX/iu), { target: { value: "ENGR7X4K" } });
		fireEvent.click(screen.getByRole("button", { name: /verify/iu }));
		fireEvent.click(await screen.findByRole("radio", { name: /personal/iu }));
		fireEvent.click(screen.getByRole("button", { name: /^sync$/iu }));

		expect(await screen.findByText(/waiting for your first sync/iu)).toBeInTheDocument();
	});

	// Obsidian registers the `obsidian://` URI scheme, so getting the user back
	// to their editor is a link, not an integration. The vault name is the one
	// the plugin sent at device-flow start — i.e. the LOCAL Obsidian vault name,
	// which is exactly what `obsidian://open?vault=` addresses.
	it("offers a deep link back to Obsidian once the vault is linked", async () => {
		get.mockResolvedValue({
			vaults: [{ id: 7, name: "Personal", note_count: 0 }],
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
			vaults: [{ id: 7, name: "Personal", note_count: 0 }],
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
				{ id: 7, name: "Personal", note_count: 0 },
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
		get.mockResolvedValue({ vaults: [{ id: 7, name: "Personal", note_count: 0 }] });
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

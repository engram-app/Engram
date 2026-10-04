import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { type AuthAdapter, AuthContext } from "../auth/auth-context";
import { type CatalogLoaders, LocaleProvider, useT } from "../i18n/locale-provider";
import { ThemeProvider } from "../theme/theme-provider";
import BillingPage from "./billing-page";

const initializePaddleMock = vi.fn();
vi.mock("@paddle/paddle-js", () => ({
	initializePaddle: (...args: unknown[]) => initializePaddleMock(...args),
	CheckoutEventNames: {},
}));

const { get } = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock("../api/client", () => ({
	api: { get, post: vi.fn(), patch: vi.fn(), del: vi.fn() },
	setTokenGetter: vi.fn(),
}));

vi.mock("phoenix", () => ({
	Socket: vi.fn(function MockSocket(this: object) {
		Object.assign(this, {
			connect: vi.fn(),
			channel: vi.fn(() => ({ on: vi.fn(), join: () => ({ receive: () => ({}) }) })),
			disconnect: vi.fn(),
		});
	}),
}));

const authAdapter: AuthAdapter = {
	isLoaded: true,
	isSignedIn: true,
	user: { email: "u@example.com" },
	getToken: async () => "tok-test",
	logout: async () => {},
	hasBuiltInUI: false,
};

const loaders: CatalogLoaders = {
	"zh-CN": async () => ({ default: { x: "y" } }),
	de: async () => ({ default: { x: "y" } }),
};

function mockBillingApi({ subscribed }: { subscribed: boolean }) {
	get.mockImplementation(async (url: string) => {
		switch (url) {
			case "/billing/status":
				return subscribed
					? {
							tier: "pro",
							active: true,
							trial_days_remaining: 0,
							subscription: {
								status: "active",
								tier: "pro",
								current_period_end: "2026-07-01T00:00:00Z",
							},
							caps: {},
						}
					: { tier: "free", active: false, trial_days_remaining: 0, subscription: null, caps: {} };
			case "/billing/config":
				return {
					client_token: "tok",
					environment: "sandbox",
					price_ids: {
						starter: { monthly: "p1", annual: "p2" },
						pro: { monthly: "p3", annual: "p4" },
					},
					customer_email: "u@example.com",
					custom_data: { user_id: "1" },
					vaults_cap: null,
				};
			case "/me":
				return { user: { id: 99, email: "u@example.com", role: "member", display_name: null } };
			case "/onboarding/status":
				return { next_step: "tools", enabled: true };
			case "/billing/subscription":
				return { next_billed_at: "2026-07-01T00:00:00Z", scheduled_change: null };
			case "/billing/transactions":
				return { payment_method: null, transactions: [] };
			case "/billing/payment-update-transaction":
				return { transaction_id: "txn_1" };
			default:
				throw new Error(`unexpected GET ${url}`);
		}
	});
}

function LocaleButtons() {
	const { setLocale } = useT();
	return (
		<button type="button" onClick={() => setLocale("de")}>
			go-de
		</button>
	);
}

function renderBilling(inline: boolean) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<AuthContext.Provider value={authAdapter}>
				<ThemeProvider>
					<LocaleProvider loaders={loaders}>
						<MemoryRouter>
							<LocaleButtons />
							{inline ? <BillingPage onActivated={() => {}} /> : <BillingPage />}
						</MemoryRouter>
					</LocaleProvider>
				</ThemeProvider>
			</AuthContext.Provider>
		</QueryClientProvider>,
	);
}

// Desktop grid and mobile accordion both render a Start button.
function startButton(): HTMLElement {
	const [first] = screen.getAllByRole("button", { name: "Start free trial" });
	if (!first) {
		throw new Error("no Start free trial button");
	}
	return first;
}

describe("BillingPage locale", () => {
	beforeEach(() => {
		window.localStorage.clear();
		window.localStorage.setItem("engram:locale", "zh-CN");
		get.mockReset();
		initializePaddleMock.mockReset();
	});

	it("passes the mapped rendered locale to a new checkout (inline)", async () => {
		mockBillingApi({ subscribed: false });
		const open = vi.fn();
		initializePaddleMock.mockImplementation(async () => ({ Checkout: { open, close: vi.fn() } }));
		renderBilling(true);
		await waitFor(() => expect(document.documentElement.lang).toBe("zh-CN"));
		await waitFor(() => expect(screen.getAllByText("Starter").length).toBeGreaterThan(0));
		await act(async () => {
			startButton().click();
			await Promise.resolve();
		});
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		expect(open.mock.calls[0]?.[0].settings).toEqual({ locale: "zh-Hans" });
	});

	it("passes the mapped rendered locale to the payment-method update checkout", async () => {
		mockBillingApi({ subscribed: true });
		const open = vi.fn();
		initializePaddleMock.mockImplementation(async () => ({ Checkout: { open, close: vi.fn() } }));
		renderBilling(false);
		await waitFor(() => expect(document.documentElement.lang).toBe("zh-CN"));
		const update = await screen.findByRole("button", { name: "Update" });
		await act(async () => {
			update.click();
			await Promise.resolve();
		});
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		expect(open.mock.calls[0]?.[0]).toEqual({
			transactionId: "txn_1",
			settings: { locale: "zh-Hans" },
		});
	});

	it("sends the current locale after a switch, without re-initializing Paddle", async () => {
		mockBillingApi({ subscribed: true });
		const open = vi.fn();
		initializePaddleMock.mockImplementation(async () => ({ Checkout: { open, close: vi.fn() } }));
		renderBilling(false);
		await waitFor(() => expect(document.documentElement.lang).toBe("zh-CN"));
		await screen.findByRole("button", { name: "Update" });
		await waitFor(() => expect(initializePaddleMock).toHaveBeenCalledTimes(1));
		await act(async () => screen.getByRole("button", { name: "go-de" }).click());
		await waitFor(() => expect(document.documentElement.lang).toBe("de"));
		await act(async () => {
			screen.getByRole("button", { name: "Update" }).click();
			await Promise.resolve();
		});
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		expect(open.mock.calls[0]?.[0].settings).toEqual({ locale: "de" });
		expect(initializePaddleMock).toHaveBeenCalledTimes(1);
	});
});

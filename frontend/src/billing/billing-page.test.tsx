import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter } from "react-router";
import { ThemeProvider } from "../theme/theme-provider";
import { AuthContext, type AuthAdapter } from "../auth/auth-context";

const initializePaddleMock = vi.fn();
vi.mock("@paddle/paddle-js", () => ({
	initializePaddle: (...args: unknown[]) => initializePaddleMock(...args),
	CheckoutEventNames: {
		CHECKOUT_LOADED: "checkout.loaded",
		CHECKOUT_CLOSED: "checkout.closed",
		CHECKOUT_COMPLETED: "checkout.completed",
		CHECKOUT_PAYMENT_INITIATED: "checkout.payment.initiated",
		CHECKOUT_PAYMENT_FAILED: "checkout.payment.failed",
		CHECKOUT_PAYMENT_ERROR: "checkout.payment.error",
		CHECKOUT_ERROR: "checkout.error",
	},
}));

const { get } = vi.hoisted(() => ({ get: vi.fn() }));
vi.mock("../api/client", () => ({
	api: { get, post: vi.fn(), patch: vi.fn(), del: vi.fn() },
	setTokenGetter: vi.fn(),
}));

// Phoenix Socket mock — capture channel handlers. Hoisted so vi.mock factory
// can reference them. Constructor function (not arrow) so `new Socket(...)`
// works with vi.fn's Mock semantics.
const { channelHandlers, socketCtor } = vi.hoisted(() => {
	const channelHandlers: Record<string, (payload: unknown) => void> = {};
	const channelMock = {
		on: (event: string, cb: (payload: unknown) => void) => {
			channelHandlers[event] = cb;
		},
		join: () => ({ receive: () => ({}) }),
	};
	const socketCtor = vi.fn(function MockSocket(this: object, ..._args: unknown[]) {
		Object.assign(this, {
			connect: vi.fn(),
			channel: vi.fn(() => channelMock),
			disconnect: vi.fn(),
		});
	});
	return { channelHandlers, socketCtor };
});
vi.mock("phoenix", () => ({ Socket: socketCtor }));

import BillingPage from "./billing-page";

const authAdapter: AuthAdapter = {
	isLoaded: true,
	isSignedIn: true,
	user: { email: "u@example.com" },
	getToken: async () => "tok-test",
	logout: async () => {},
	hasBuiltInUI: false,
};

const ME = { id: 99, email: "u@example.com", role: "member" as const, display_name: null };

describe("BillingPage — Paddle effect cleanup", () => {
	beforeEach(() => {
		get.mockReset();
		initializePaddleMock.mockReset();
		socketCtor.mockClear();
		for (const k of Object.keys(channelHandlers)) delete channelHandlers[k];
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("Paddle effect cleanup: post-unmount eventCallback invocations are inert", async () => {
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status")
				return {
					tier: "free",
					active: false,
					trial_days_remaining: 0,
					subscription: null,
					caps: {},
				};
			if (url === "/billing/config")
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
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") return { next_step: "tools", enabled: true };
			throw new Error(`unexpected GET ${url}`);
		});

		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn() } };
		});

		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		const { unmount } = render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter>
							<BillingPage onActivated={() => {}} />
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);

		await waitFor(() => expect(captured).toBeDefined());

		unmount();

		expect(() =>
			captured!({ name: "checkout.payment.initiated", data: { transaction_id: "late" } }),
		).not.toThrow();
	});

	// Mocks for the inline-checkout flow tests below. Returns the same shapes
	// as the other tests; factored so the new tests stay short.
	function mockBillingApi() {
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status")
				return {
					tier: "free",
					active: false,
					trial_days_remaining: 0,
					subscription: null,
					caps: {},
				};
			if (url === "/billing/config")
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
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") return { next_step: "tools", enabled: true };
			throw new Error(`unexpected GET ${url}`);
		});
	}

	function renderBilling({ inline }: { inline: boolean }) {
		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		const utils = render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter>
							{inline ? <BillingPage onActivated={() => {}} /> : <BillingPage />}
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);
		return { qc, ...utils };
	}

	it("onboarding (inline): initializes Paddle with displayMode=inline and frameTarget", async () => {
		mockBillingApi();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: vi.fn() },
		}));

		renderBilling({ inline: true });

		await waitFor(() => expect(initializePaddleMock).toHaveBeenCalled());
		const settings = initializePaddleMock.mock.calls[0]![0].checkout.settings;
		expect(settings.displayMode).toBe("inline");
		expect(settings.frameTarget).toBe("paddle-checkout");
	});

	it("settings (overlay): initializes Paddle with displayMode=overlay", async () => {
		mockBillingApi();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: vi.fn() },
		}));

		renderBilling({ inline: false });

		await waitFor(() => expect(initializePaddleMock).toHaveBeenCalled());
		const settings = initializePaddleMock.mock.calls[0]![0].checkout.settings;
		expect(settings.displayMode).toBe("overlay");
	});

	it("onboarding (inline): clicking Start trial swaps plan cards for inline mount target", async () => {
		mockBillingApi();
		const openMock = vi.fn();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: openMock, close: vi.fn() },
		}));

		const { container, queryAllByText } = renderBilling({ inline: true });

		// Wait for the Paddle instance to land and plan cards to render. "Starter"
		// appears twice — the desktop card grid and the mobile accordion are both
		// in the DOM (CSS, not JS, hides one), so assert on the count.
		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));

		const startButtons = container.querySelectorAll("button");
		const startBtn = Array.from(startButtons).find((b) => b.textContent === "Start free trial");
		expect(startBtn).toBeDefined();

		await act(async () => {
			startBtn!.click();
			await Promise.resolve();
		});

		// Plan cards hidden, mount target rendered, Paddle.Checkout.open invoked
		expect(container.querySelector(".paddle-checkout")).not.toBeNull();
		expect(queryAllByText("Starter")).toHaveLength(0);
		expect(openMock).toHaveBeenCalledTimes(1);
	});

	it("onboarding (inline): CHECKOUT_PAYMENT_FAILED restores the plan picker", async () => {
		mockBillingApi();
		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: vi.fn() } };
		});

		const { container, queryAllByText } = renderBilling({ inline: true });

		// "Starter" renders twice (desktop card + mobile accordion); assert count.
		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
		const startBtn = Array.from(container.querySelectorAll("button")).find(
			(b) => b.textContent === "Start free trial",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});

		expect(container.querySelector(".paddle-checkout")).not.toBeNull();

		await act(async () => {
			captured!({ name: "checkout.payment.failed", data: { transaction_id: "txn_x" } });
			await Promise.resolve();
		});

		// Mount target gone, plan cards back
		expect(container.querySelector(".paddle-checkout")).toBeNull();
		expect(queryAllByText("Starter").length).toBeGreaterThan(0);
	});

	it("onboarding (inline): cooldown arms on CHECKOUT_PAYMENT_INITIATED so a dropped COMPLETED still surfaces the recovery banner", async () => {
		// Pre-#440 belt-and-suspenders: PAYMENT_INITIATED may drop on trial-signup
		// redirects (and so may COMPLETED). The cooldown timer must be anchored
		// to whichever event fires first, otherwise a missing COMPLETED leaves
		// the user stuck on Paddle's inline frame forever with no recovery.
		vi.useFakeTimers({ shouldAdvanceTime: true });
		mockBillingApi();
		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: vi.fn() } };
		});

		renderBilling({ inline: true });

		await waitFor(() => expect(captured).toBeDefined());
		// Let the initializePaddle .then() resolve.
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		// PAYMENT_INITIATED fires; COMPLETED never does (the drop case).
		await act(async () => {
			captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_drop_99" } });
			await Promise.resolve();
		});

		// Past the 15s cooldown window, recovery banner must appear.
		await act(async () => {
			vi.advanceTimersByTime(15_500);
			await Promise.resolve();
		});

		await waitFor(() =>
			expect(
				screen.queryByText(/Payment received\. We're finishing your activation/i),
			).toBeInTheDocument(),
		);
	});

	it("onboarding (inline): closes Paddle and fires onActivated when subscription_activated push arrives", async () => {
		mockBillingApi();
		const closeMock = vi.fn();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: closeMock },
		}));

		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		qc.setQueryData(["onboarding", "status"], { next_step: "tools" });
		const onActivated = vi.fn();
		render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter>
							<BillingPage onActivated={onActivated} />
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);

		await waitFor(() => expect(channelHandlers["subscription_activated"]).toBeDefined());
		// Wait for paddle instance to land
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		await act(async () => {
			channelHandlers["subscription_activated"]!({
				tier: "starter",
				status: "trialing",
				subscription_id: "sub_1",
			});
			await Promise.resolve();
		});

		await waitFor(() => expect(onActivated).toHaveBeenCalled());
		expect(closeMock).toHaveBeenCalled();
	});

	it("invalidates billing/status on subscription_activated channel event (settings flow)", async () => {
		let billingActive = false;
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") {
				return billingActive
					? {
							tier: "starter",
							active: true,
							trial_days_remaining: 7,
							subscription: { status: "trialing", tier: "starter" },
							caps: {},
						}
					: {
							tier: "free",
							active: false,
							trial_days_remaining: 0,
							subscription: null,
							caps: {},
						};
			}
			if (url === "/billing/config")
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
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") return { next_step: "tools", enabled: true };
			throw new Error(`unexpected GET ${url}`);
		});

		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: vi.fn() },
		}));

		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");
		render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter>
							{/* No onActivated — settings flow */}
							<BillingPage />
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);

		await waitFor(() => expect(channelHandlers["subscription_activated"]).toBeDefined());

		billingActive = true;
		await act(async () => {
			channelHandlers["subscription_activated"]!({
				tier: "starter",
				status: "trialing",
				subscription_id: "sub_settings",
			});
			await Promise.resolve();
		});

		await waitFor(() => {
			const billingStatusInvalidations = invalidateSpy.mock.calls.filter(([arg]) => {
				const key = (arg as { queryKey?: unknown[] })?.queryKey;
				return Array.isArray(key) && key[0] === "billing" && key[1] === "status";
			});
			expect(billingStatusInvalidations.length).toBeGreaterThan(0);
		});
	});

	it("upgrade: CHECKOUT_COMPLETED invalidates billing/status and capabilities (#603)", async () => {
		// The bug: an upgrade's CHECKOUT_COMPLETED invalidated only subscription +
		// transactions, never ['billing','status'] or ['capabilities']. The
		// activation push + onboarding poll didn't cover it (next_step is already
		// 'done' on upgrade), so every useBillingStatus() consumer stayed on the
		// old tier until a manual refresh.
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status")
				return {
					tier: "free",
					active: false,
					trial_days_remaining: 0,
					subscription: null,
					caps: {},
				};
			if (url === "/billing/config")
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
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") return { next_step: "done", enabled: true };
			throw new Error(`unexpected GET ${url}`);
		});

		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: vi.fn() } };
		});

		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		const invalidateSpy = vi.spyOn(qc, "invalidateQueries");
		render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter>
							{/* Settings flow (no onActivated) — the upgrade path. */}
							<BillingPage />
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);

		await waitFor(() => expect(captured).toBeDefined());
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		await act(async () => {
			captured!({ name: "checkout.completed", data: { transaction_id: "txn_up_1" } });
			await Promise.resolve();
		});

		const keyFired = (k0: string, k1?: string) =>
			invalidateSpy.mock.calls.some(([arg]) => {
				const key = (arg as { queryKey?: unknown[] })?.queryKey;
				return Array.isArray(key) && key[0] === k0 && (k1 === undefined || key[1] === k1);
			});

		await waitFor(() => {
			expect(keyFired("billing", "status")).toBe(true);
			expect(keyFired("capabilities")).toBe(true);
		});
	});

	it("subscribed flow: Cancel button opens CancelPanel inline (no portal redirect)", async () => {
		initializePaddleMock.mockResolvedValue({ Checkout: { open: vi.fn(), close: vi.fn() } });

		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status")
				return {
					tier: "pro",
					active: true,
					trial_days_remaining: 0,
					subscription: {
						status: "active",
						tier: "pro",
						current_period_end: "2026-07-01T00:00:00Z",
					},
					caps: {},
				};
			if (url === "/billing/config")
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
			if (url === "/me") return { user: ME };
			if (url === "/billing/subscription")
				return { next_billed_at: "2026-07-01T00:00:00Z", scheduled_change: null };
			if (url === "/billing/transactions") return { payment_method: null, transactions: [] };
			throw new Error(`unexpected GET ${url}`);
		});

		renderBilling({ inline: false });

		const cancelButton = await screen.findByRole("button", { name: /cancel subscription/i });
		await act(async () => {
			cancelButton.click();
		});

		// CancelPanel header is visible; button row collapses.
		await screen.findByRole("region", { name: /cancel subscription/i });
		expect(screen.getByRole("button", { name: /cancel at period end/i })).toBeInTheDocument();
	});

	it("subscribed flow: Change plan button opens PlanChangePanel inline", async () => {
		initializePaddleMock.mockResolvedValue({ Checkout: { open: vi.fn(), close: vi.fn() } });

		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status")
				return {
					tier: "starter",
					active: true,
					trial_days_remaining: 0,
					subscription: {
						status: "active",
						tier: "starter",
						current_period_end: "2026-07-01T00:00:00Z",
					},
					caps: {},
				};
			if (url === "/billing/config")
				return {
					client_token: "tok",
					environment: "sandbox",
					price_ids: {
						starter: { monthly: "p1", annual: "p2" },
						pro: { monthly: "p3", annual: "p4" },
					},
					customer_email: "u@example.com",
					custom_data: { user_id: "1" },
					vaults_cap: 5,
				};
			if (url === "/me") return { user: ME };
			if (url === "/billing/subscription")
				return { next_billed_at: "2026-07-01T00:00:00Z", scheduled_change: null };
			if (url === "/billing/transactions") return { payment_method: null, transactions: [] };
			throw new Error(`unexpected GET ${url}`);
		});

		renderBilling({ inline: false });

		const changeButton = await screen.findByRole("button", { name: /change plan/i });
		await act(async () => {
			changeButton.click();
		});

		await screen.findByRole("region", { name: /change plan/i });
	});
});

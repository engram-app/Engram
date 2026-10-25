import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { track } from "../analytics/track";
import { type AuthAdapter, AuthContext } from "../auth/auth-context";
import { ThemeProvider, useTheme } from "../theme/theme-provider";
import BillingPage from "./billing-page";

vi.mock("../analytics/track", () => ({ track: vi.fn() }));
const mockTrack = vi.mocked(track);

const initializePaddleMock = vi.fn();
vi.mock("@paddle/paddle-js", () => ({
	initializePaddle: (...args: unknown[]) => initializePaddleMock(...args),
	CheckoutEventNames: {
		CHECKOUT_LOADED: "checkout.loaded",
		CHECKOUT_CLOSED: "checkout.closed",
		CHECKOUT_COMPLETED: "checkout.completed",
		CHECKOUT_PAYMENT_INITIATED: "checkout.payment.initiated",
		CHECKOUT_PAYMENT_SELECTED: "checkout.payment.selected",
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

const authAdapter: AuthAdapter = {
	isLoaded: true,
	isSignedIn: true,
	user: { email: "u@example.com" },
	getToken: async () => "tok-test",
	logout: async () => {},
	hasBuiltInUI: false,
};

const ME = {
	id: 99,
	email: "u@example.com",
	role: "member" as const,
	display_name: null,
};

describe("BillingPage — Paddle effect cleanup", () => {
	beforeEach(() => {
		get.mockReset();
		initializePaddleMock.mockReset();
		socketCtor.mockClear();
		mockTrack.mockClear();
		for (const k of Object.keys(channelHandlers)) {
			delete channelHandlers[k];
		}
	});

	afterEach(() => {
		vi.useRealTimers();
	});

	it("Paddle effect cleanup: post-unmount eventCallback invocations are inert", async () => {
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") {
				return {
					tier: "free",
					active: false,
					trial_days_remaining: 0,
					subscription: null,
					caps: {},
				};
			}
			if (url === "/billing/config") {
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
			}
			if (url === "/me") {
				return { user: ME };
			}
			if (url === "/onboarding/status") {
				return { next_step: "tools", enabled: true };
			}
			throw new Error(`unexpected GET ${url}`);
		});

		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn() } };
		});

		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false } },
		});
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
			captured!({
				name: "checkout.payment.initiated",
				data: { transaction_id: "late" },
			}),
		).not.toThrow();
	});

	// Mocks for the inline-checkout flow tests below. Returns the same shapes
	// as the other tests; factored so the new tests stay short.
	function mockBillingApi() {
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") {
				return {
					tier: "free",
					active: false,
					trial_days_remaining: 0,
					subscription: null,
					caps: {},
				};
			}
			if (url === "/billing/config") {
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
			}
			if (url === "/me") {
				return { user: ME };
			}
			if (url === "/onboarding/status") {
				return { next_step: "tools", enabled: true };
			}
			throw new Error(`unexpected GET ${url}`);
		});
	}

	function renderBilling({ inline }: { inline: boolean }) {
		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false } },
		});
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
		const { settings } = initializePaddleMock.mock.calls[0]![0].checkout;
		expect(settings.displayMode).toBe("inline");
		expect(settings.frameTarget).toBe("paddle-checkout");
	});

	// Annual is the default cadence because it buys retention, NOT because it
	// saves on Paddle fees — the 17% discount costs more than the flat $0.50
	// per-transaction fee saves. See pricing-tiers-v2-decisions.md.
	it("plan picker defaults to the annual cadence", async () => {
		mockBillingApi();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: vi.fn() },
		}));

		renderBilling({ inline: false });

		const annual = await screen.findByRole("radio", { name: /annual/iu });
		expect((annual as HTMLInputElement).checked).toBe(true);
		const monthly = screen.getByRole("radio", { name: /monthly/iu });
		expect((monthly as HTMLInputElement).checked).toBe(false);
	});

	it("settings (overlay): initializes Paddle with displayMode=overlay", async () => {
		mockBillingApi();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: vi.fn() },
		}));

		renderBilling({ inline: false });

		await waitFor(() => expect(initializePaddleMock).toHaveBeenCalled());
		const { settings } = initializePaddleMock.mock.calls[0]![0].checkout;
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
		const startBtn = Array.from(startButtons).find((b) => b.textContent === "Choose Starter");
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

	// #2202 hid Apple Pay and Google Pay, but the wallet stalls were our own
	// cooldown closing the checkout under the wallet sheet (armed on
	// PAYMENT_INITIATED), not the wallets. In-app checkout offers every method.
	it("plan checkout does not restrict payment methods (wallets offered)", async () => {
		mockBillingApi();
		const openMock = vi.fn();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: openMock, close: vi.fn() },
		}));

		const { container, queryAllByText } = renderBilling({ inline: true });
		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
		const startBtn = Array.from(container.querySelectorAll("button")).find(
			(b) => b.textContent === "Choose Starter",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});

		expect(openMock.mock.calls[0]![0].settings.allowedPaymentMethods).toBeUndefined();
		const { settings } = initializePaddleMock.mock.calls[0]![0].checkout;
		expect(settings.allowedPaymentMethods).toBeUndefined();
	});

	// Paddle: pass customer id OR email, not both. With a known id the buyer
	// stays one Paddle customer; allowLogout:false stops them switching email
	// inside checkout and splitting into a second one.
	it.each([
		["known Paddle customer: prefills by id", "ctm_known", { id: "ctm_known" }],
		["new buyer: prefills by email", null, { email: "u@example.com" }],
	])("plan checkout %s and blocks logout", async (_label, customerId, expected) => {
		mockBillingApi();
		const base = get.getMockImplementation()!;
		get.mockImplementation(async (url: string) => {
			const body = await base(url);
			return url === "/billing/config" ? { ...body, customer_id: customerId } : body;
		});
		const openMock = vi.fn();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: openMock, close: vi.fn() },
		}));

		const { container, queryAllByText } = renderBilling({ inline: true });
		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
		const startBtn = Array.from(container.querySelectorAll("button")).find(
			(b) => b.textContent === "Choose Starter",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});
		await waitFor(() => expect(openMock).toHaveBeenCalledTimes(1));

		expect(openMock.mock.calls[0]![0].customer).toEqual(expected);
		expect(openMock.mock.calls[0]![0].settings.allowLogout).toBe(false);
	});

	describe("checkout funnel tracking", () => {
		function startCheckout(container: HTMLElement) {
			const startBtn = Array.from(container.querySelectorAll("button")).find(
				(b) => b.textContent === "Choose Starter",
			)!;
			return act(async () => {
				startBtn.click();
				await Promise.resolve();
			});
		}

		it("emits checkout_opened with method unknown and the tier being checked out, on CHECKOUT_LOADED", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			await act(async () => {
				captured!({ name: "checkout.loaded", data: {} });
				await Promise.resolve();
			});

			// Annual is the default cadence; nothing upstream named a source.
			expect(mockTrack).toHaveBeenCalledWith("checkout_opened", {
				method: "unknown",
				tier: "starter",
				cadence: "annual",
				source: "direct",
			});
		});

		it("emits checkout_completed with the method selected mid-checkout", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			await act(async () => {
				captured!({
					name: "checkout.payment.selected",
					data: { payment: { method_details: { type: "apple-pay" } } },
				});
				await Promise.resolve();
			});
			await act(async () => {
				captured!({ name: "checkout.completed", data: {} });
				await Promise.resolve();
			});

			expect(mockTrack).toHaveBeenCalledWith("checkout_completed", { method: "apple_pay" });
		});

		// This is the signal the four dead Apple Pay attempts on 2026-09-06
		// needed — a declined/failed payment, not the dismissed-native-sheet
		// case this Paddle.js integration has no event for at all (see the
		// task report).
		it("emits checkout_stalled on CHECKOUT_PAYMENT_FAILED", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			await act(async () => {
				captured!({
					name: "checkout.payment.selected",
					data: { payment: { method_details: { type: "apple-pay" } } },
				});
				await Promise.resolve();
			});
			await act(async () => {
				captured!({ name: "checkout.payment.failed", data: {} });
				await Promise.resolve();
			});

			expect(mockTrack).toHaveBeenCalledWith("checkout_stalled", {
				method: "apple_pay",
				reason: "payment_declined",
			});
		});

		it("emits checkout_abandoned on CHECKOUT_CLOSED without a prior completion", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			await act(async () => {
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});

			expect(mockTrack).toHaveBeenCalledWith(
				"checkout_abandoned",
				{ method: "unknown" },
				{ beacon: false },
			);
		});

		// Paddle.js has no event for a payment parked at action_required (a
		// dismissed Apple Pay sheet, an unanswered 3DS challenge). The visible
		// symptom is a buyer who started paying and then left: report it.
		it("emits checkout_stalled when checkout closes after a payment attempt started", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			await act(async () => {
				captured!({
					name: "checkout.payment.selected",
					data: { payment: { method_details: { type: "apple-pay" } } },
				});
				captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});

			expect(mockTrack).toHaveBeenCalledWith(
				"checkout_stalled",
				{ method: "apple_pay", reason: "payment_unfinished" },
				{ beacon: false },
			);
			expect(mockTrack).toHaveBeenCalledWith(
				"checkout_abandoned",
				{ method: "apple_pay" },
				{ beacon: false },
			);
		});

		it("reports a declined attempt once, not again as unfinished on close", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);
			await act(async () => {
				captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
				captured!({ name: "checkout.payment.failed", data: {} });
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});

			const stalls = mockTrack.mock.calls.filter(([e]) => e === "checkout_stalled");
			expect(stalls).toEqual([
				["checkout_stalled", { method: "unknown", reason: "payment_declined" }],
			]);
		});

		it("does not report an abandon on pagehide after a checkout error", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);
			await act(async () => {
				captured!({ name: "checkout.error", data: {} });
				await Promise.resolve();
			});
			window.dispatchEvent(new Event("pagehide"));

			expect(mockTrack.mock.calls.filter(([e]) => e === "checkout_abandoned")).toEqual([]);
		});

		it("does not report a stall when the buyer closes before trying to pay", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);
			await act(async () => {
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});

			expect(mockTrack).not.toHaveBeenCalledWith("checkout_stalled", expect.anything());
		});

		// Most real abandons close the tab, so checkout.closed never fires.
		it("beacons checkout_abandoned on pagehide while a checkout is open, once", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			window.dispatchEvent(new Event("pagehide"));
			window.dispatchEvent(new Event("pagehide"));
			await act(async () => {
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});

			const abandons = mockTrack.mock.calls.filter(([e]) => e === "checkout_abandoned");
			expect(abandons).toEqual([["checkout_abandoned", { method: "unknown" }, { beacon: true }]]);
		});

		// After a payment starts, the server (webhooks + the stalled scan) is the
		// authority: a dropped checkout.completed on a redirect, or a redirect-
		// based payment method navigating away, must not report a paying buyer.
		it("sends nothing on pagehide once a payment attempt has started", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);
			await act(async () => {
				captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
				await Promise.resolve();
			});
			window.dispatchEvent(new Event("pagehide"));

			const exits = mockTrack.mock.calls.filter(
				([e]) => e === "checkout_abandoned" || e === "checkout_stalled",
			);
			expect(exits).toEqual([]);
		});

		// bfcache entry (persisted) is not a departure: the page may come back
		// and the buyer finish, so it must not report, nor burn the once-latch.
		it("ignores a persisted pagehide (bfcache) and still reports the real exit", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);
			// happy-dom's PageTransitionEvent drops the `persisted` init field.
			const toBfcache = new Event("pagehide");
			Object.defineProperty(toBfcache, "persisted", { value: true });
			window.dispatchEvent(toBfcache);
			expect(mockTrack.mock.calls.filter(([e]) => e === "checkout_abandoned")).toEqual([]);

			await act(async () => {
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});
			expect(mockTrack).toHaveBeenCalledWith(
				"checkout_abandoned",
				{ method: "unknown" },
				{ beacon: false },
			);
		});

		// checkout.loaded is per checkout (Paddle docs), but a repeat for the
		// SAME checkout id must not wipe an attempt already in flight.
		it("keeps the attempt when checkout.loaded repeats for the same checkout", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);
			await act(async () => {
				captured!({ name: "checkout.loaded", data: { id: "che_1" } });
				captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
				captured!({ name: "checkout.loaded", data: { id: "che_1" } });
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});

			expect(mockTrack).toHaveBeenCalledWith(
				"checkout_stalled",
				{ method: "unknown", reason: "payment_unfinished" },
				{ beacon: false },
			);
		});

		it("sends nothing on pagehide when no checkout is open or it completed", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			window.dispatchEvent(new Event("pagehide"));
			await startCheckout(container);
			await act(async () => {
				captured!({ name: "checkout.completed", data: {} });
				await Promise.resolve();
			});
			window.dispatchEvent(new Event("pagehide"));

			expect(mockTrack).not.toHaveBeenCalledWith(
				"checkout_abandoned",
				expect.anything(),
				expect.anything(),
			);
			expect(mockTrack).not.toHaveBeenCalledWith("checkout_abandoned", expect.anything());
		});

		it("does not emit checkout_abandoned on CHECKOUT_CLOSED after a completion", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: vi.fn() } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			await act(async () => {
				captured!({ name: "checkout.completed", data: {} });
				await Promise.resolve();
			});
			mockTrack.mockClear();
			await act(async () => {
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});

			expect(mockTrack).not.toHaveBeenCalledWith("checkout_abandoned", expect.anything());
		});

		// The activation push can beat Paddle.js's checkout.completed. Our own
		// Checkout.close() then fires checkout.closed on a paid checkout, which
		// must not read as a stall or an abandon (#2203).
		it("does not emit checkout_stalled/abandoned when the activation push closes the checkout first", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return {
					Checkout: {
						open: vi.fn(),
						close: vi.fn(() => captured!({ name: "checkout.closed", data: {} })),
					},
				};
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			await act(async () => {
				captured!({ name: "checkout.loaded", data: {} });
				captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
				await Promise.resolve();
			});
			await act(async () => {
				channelHandlers.subscription_activated!({
					tier: "starter",
					status: "trialing",
					subscription_id: "sub_1",
				});
				await Promise.resolve();
			});

			const exits = mockTrack.mock.calls.filter(
				([e]) => e === "checkout_stalled" || e === "checkout_abandoned",
			);
			expect(exits).toEqual([]);
			expect(mockTrack).toHaveBeenCalledWith("checkout_completed", { method: "unknown" });
			// The push won, so the completion is reported from it, once: a late
			// checkout.completed from Paddle.js must not count it twice.
			await act(async () => {
				captured!({ name: "checkout.completed", data: {} });
				await Promise.resolve();
			});
			expect(mockTrack.mock.calls.filter(([e]) => e === "checkout_completed")).toEqual([
				["checkout_completed", { method: "unknown" }],
			]);
		});

		// subscription_activated is user-scoped and also fires for an OLD
		// subscription's update or cancel. Only a push that shows a paying
		// subscription counts as this checkout's completion; anything else must
		// leave a real stall reported.
		it("still reports the stall when the push is not a paying subscription", async () => {
			mockBillingApi();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return {
					Checkout: {
						open: vi.fn(),
						close: vi.fn(() => captured!({ name: "checkout.closed", data: {} })),
					},
				};
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			await startCheckout(container);

			await act(async () => {
				captured!({ name: "checkout.loaded", data: {} });
				captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
				await Promise.resolve();
			});
			await act(async () => {
				channelHandlers.subscription_activated!({
					tier: "starter",
					status: "canceled",
					subscription_id: "sub_old",
				});
				await Promise.resolve();
			});
			// The push leaves the checkout open; the buyer then closes it.
			await act(async () => {
				captured!({ name: "checkout.closed", data: {} });
				await Promise.resolve();
			});

			expect(mockTrack).toHaveBeenCalledWith(
				"checkout_stalled",
				{ method: "unknown", reason: "payment_unfinished" },
				{ beacon: false },
			);
			expect(mockTrack).not.toHaveBeenCalledWith("checkout_completed", expect.anything());
		});
	});

	// subscription_activated fires on every subscription mutation, including an
	// older subscription going canceled or past_due. Closing Paddle on those
	// killed a live wallet sheet mid-payment.
	it.each(["canceled", "past_due"])(
		"onboarding (inline): a %s push during an open checkout does not close Paddle",
		async (status) => {
			mockBillingApi();
			const closeMock = vi.fn();
			let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
			initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
				captured = opts.eventCallback;
				return { Checkout: { open: vi.fn(), close: closeMock } };
			});

			const { container, queryAllByText } = renderBilling({ inline: true });
			await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
			const startBtn = Array.from(container.querySelectorAll("button")).find(
				(b) => b.textContent === "Choose Starter",
			)!;
			await act(async () => {
				startBtn.click();
				await Promise.resolve();
			});
			await act(async () => {
				captured!({ name: "checkout.loaded", data: {} });
				captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
				await Promise.resolve();
			});
			await waitFor(() => expect(channelHandlers.subscription_activated).toBeDefined());
			await act(async () => {
				channelHandlers.subscription_activated!({
					tier: "starter",
					status,
					subscription_id: "sub_old",
				});
				await Promise.resolve();
			});

			expect(closeMock).not.toHaveBeenCalled();
			expect(container.querySelector(".paddle-checkout")).toBeInTheDocument();
		},
	);

	it("onboarding (inline): CHECKOUT_PAYMENT_FAILED keeps Paddle's frame open so the decline reason + retry stay visible", async () => {
		// A declined card is a normal, retryable state: Paddle keeps its inline
		// frame open and shows the reason ("card declined" etc.) with a retry.
		// We must NOT tear the frame down — doing so bounced the user back to the
		// plan picker with no explanation. (Genuine checkout.error / payment.error
		// events still close; see the next test.)
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
			(b) => b.textContent === "Choose Starter",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});

		expect(container.querySelector(".paddle-checkout")).not.toBeNull();

		await act(async () => {
			captured!({
				name: "checkout.payment.failed",
				data: { transaction_id: "txn_x" },
			});
			await Promise.resolve();
		});

		// Frame stays mounted; user is NOT bounced to the plan picker.
		expect(container.querySelector(".paddle-checkout")).not.toBeNull();
		expect(queryAllByText("Starter").length).toBe(0);
	});

	it("onboarding (inline): a genuine CHECKOUT_ERROR closes the frame and surfaces a message", async () => {
		mockBillingApi();
		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: vi.fn() } };
		});

		const { container, queryAllByText } = renderBilling({ inline: true });

		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
		const startBtn = Array.from(container.querySelectorAll("button")).find(
			(b) => b.textContent === "Choose Starter",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});
		expect(container.querySelector(".paddle-checkout")).not.toBeNull();

		await act(async () => {
			captured!({ name: "checkout.error", data: {} });
			await Promise.resolve();
		});

		// Fatal checkout error: frame gone, plan picker restored.
		expect(container.querySelector(".paddle-checkout")).toBeNull();
		expect(queryAllByText("Starter").length).toBeGreaterThan(0);
	});

	it("settings (overlay): Paddle theme is fixed to light and does not follow the app's live theme", async () => {
		// Paddle's branded-inline-checkout dashboard config is a single static
		// color set with no light/dark variant, tuned for light — feeding it a
		// live theme just produces mismatched contrast, so `theme: "light"` is
		// a fixed constant. An app theme flip must neither change it nor
		// rebuild the Paddle instance.
		mockBillingApi();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: vi.fn() },
		}));

		function Harness() {
			const { setTheme } = useTheme();
			return (
				<>
					<button type="button" onClick={() => setTheme("light")}>
						go-light
					</button>
					<button type="button" onClick={() => setTheme("dark")}>
						go-dark
					</button>
					<BillingPage />
				</>
			);
		}

		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false } },
		});
		render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter>
							<Harness />
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);

		await waitFor(() => expect(initializePaddleMock).toHaveBeenCalledTimes(1));
		expect(initializePaddleMock.mock.calls[0]![0].checkout.settings.theme).toBe("light");

		await act(async () => {
			screen.getByRole("button", { name: "go-light" }).click();
			screen.getByRole("button", { name: "go-dark" }).click();
			await Promise.resolve();
		});

		// No rebuild — the checkout settings never depended on app theme at all.
		expect(initializePaddleMock).toHaveBeenCalledTimes(1);
	});

	// Paddle fires PAYMENT_INITIATED when the buyer taps Apple Pay / Google Pay,
	// before the wallet sheet opens. Arming the cooldown there closed the
	// checkout under an open wallet sheet at ~15 s and claimed the payment was
	// received. Only CHECKOUT_COMPLETED may arm it.
	it("onboarding (inline): PAYMENT_INITIATED alone never closes checkout or claims payment received", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		mockBillingApi();
		const closeMock = vi.fn();
		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: closeMock } };
		});

		const { container, queryAllByText } = renderBilling({ inline: true });
		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
		const startBtn = Array.from(container.querySelectorAll("button")).find(
			(b) => b.textContent === "Choose Starter",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});

		await act(async () => {
			captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_wallet" } });
			await Promise.resolve();
		});
		await act(async () => {
			vi.advanceTimersByTime(20_000);
			await Promise.resolve();
		});

		expect(closeMock).not.toHaveBeenCalled();
		expect(screen.queryByText(/received|activating|activation/iu)).not.toBeInTheDocument();
		expect(container.querySelector(".paddle-checkout")).toBeInTheDocument();
	});

	it("onboarding (inline): closing checkout mid-payment says the buyer is not subscribed and Try again reopens it", async () => {
		mockBillingApi();
		const openMock = vi.fn();
		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: openMock, close: vi.fn() } };
		});

		const { container, queryAllByText } = renderBilling({ inline: true });
		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
		const startBtn = Array.from(container.querySelectorAll("button")).find(
			(b) => b.textContent === "Choose Starter",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});
		await waitFor(() => expect(openMock).toHaveBeenCalledTimes(1));

		await act(async () => {
			captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
			captured!({ name: "checkout.closed", data: {} });
			await Promise.resolve();
		});

		expect(
			screen.getByText("Your payment did not finish, so you have not been subscribed."),
		).toBeInTheDocument();
		expect(screen.queryByText(/received|activating/iu)).not.toBeInTheDocument();

		await act(async () => {
			screen.getByRole("button", { name: "Try again" }).click();
			await Promise.resolve();
		});
		await waitFor(() => expect(openMock).toHaveBeenCalledTimes(2));
		expect(openMock.mock.calls[1]![0].items).toEqual(openMock.mock.calls[0]![0].items);
		expect(
			screen.queryByText("Your payment did not finish, so you have not been subscribed."),
		).not.toBeInTheDocument();
	});

	it("onboarding (inline): our own close after an activation push is not reported as an unfinished payment", async () => {
		mockBillingApi();
		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: vi.fn() } };
		});

		const { container, queryAllByText } = renderBilling({ inline: true });
		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
		const startBtn = Array.from(container.querySelectorAll("button")).find(
			(b) => b.textContent === "Choose Starter",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});

		await act(async () => {
			captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
			await Promise.resolve();
		});
		await waitFor(() => expect(channelHandlers.subscription_activated).toBeDefined());
		await act(async () => {
			channelHandlers.subscription_activated!({ tier: "starter", status: "active" });
			// The push handler's Checkout.close() makes Paddle emit checkout.closed.
			captured!({ name: "checkout.closed", data: {} });
			await Promise.resolve();
		});

		expect(
			screen.queryByText("Your payment did not finish, so you have not been subscribed."),
		).not.toBeInTheDocument();
	});

	it("onboarding (inline): COMPLETED with no activation push closes Paddle and shows the recovery banner after the cooldown", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		mockBillingApi();
		const closeMock = vi.fn();
		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: closeMock } };
		});

		renderBilling({ inline: true });
		await waitFor(() => expect(captured).toBeDefined());
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		await act(async () => {
			captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_99" } });
			captured!({ name: "checkout.completed", data: {} });
			await Promise.resolve();
		});
		await act(async () => {
			vi.advanceTimersByTime(15_500);
			await Promise.resolve();
		});

		await waitFor(() =>
			expect(
				screen.queryByText(/Payment received\. We're finishing your activation/iu),
			).toBeInTheDocument(),
		);
		expect(closeMock).toHaveBeenCalled();
	});

	it("onboarding (inline): the recovery banner (slow) does NOT get the forced-light frame treatment, even though the wrapper is still told checkout is active", async () => {
		// onCheckoutActiveChange (broad: checkingOut || slow || finalizing) drives
		// header-hiding and stays true here. onCheckoutFrameActiveChange (narrow:
		// only while the Paddle frame itself renders) drives the wrapper's
		// forced-light card and must flip back to false once slow replaces the
		// frame with our own theme-aware SlowActivationBanner — otherwise that
		// banner's text renders light-on-white in dark mode.
		vi.useFakeTimers({ shouldAdvanceTime: true });
		mockBillingApi();
		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: vi.fn() } };
		});

		const onCheckoutActiveChange = vi.fn();
		const onCheckoutFrameActiveChange = vi.fn();
		const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
		const { container, queryAllByText } = render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter>
							<BillingPage
								onActivated={() => {}}
								onCheckoutActiveChange={onCheckoutActiveChange}
								onCheckoutFrameActiveChange={onCheckoutFrameActiveChange}
							/>
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);

		await waitFor(() => expect(queryAllByText("Starter").length).toBeGreaterThan(0));
		const startBtn = Array.from(container.querySelectorAll("button")).find(
			(b) => b.textContent === "Choose Starter",
		)!;
		await act(async () => {
			startBtn.click();
			await Promise.resolve();
		});

		expect(onCheckoutActiveChange).toHaveBeenLastCalledWith(true);
		expect(onCheckoutFrameActiveChange).toHaveBeenLastCalledWith(true);

		await act(async () => {
			captured!({ name: "checkout.payment.initiated", data: { transaction_id: "txn_1" } });
			captured!({ name: "checkout.completed", data: {} });
			await Promise.resolve();
		});
		await act(async () => {
			vi.advanceTimersByTime(15_500);
			await Promise.resolve();
		});

		await waitFor(() =>
			expect(
				screen.queryByText(/Payment received\. We're finishing your activation/iu),
			).toBeInTheDocument(),
		);
		expect(onCheckoutActiveChange).toHaveBeenLastCalledWith(true);
		expect(onCheckoutFrameActiveChange).toHaveBeenLastCalledWith(false);
	});

	it("onboarding (inline): closes Paddle and fires onActivated when subscription_activated push arrives", async () => {
		mockBillingApi();
		const closeMock = vi.fn();
		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: closeMock },
		}));

		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false } },
		});
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

		await waitFor(() => expect(channelHandlers.subscription_activated).toBeDefined());
		// Wait for paddle instance to land
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		await act(async () => {
			channelHandlers.subscription_activated!({
				tier: "starter",
				status: "trialing",
				subscription_id: "sub_1",
			});
			await Promise.resolve();
		});

		await waitFor(() => expect(onActivated).toHaveBeenCalled());
		expect(closeMock).toHaveBeenCalled();
	});

	it("onboarding (inline): the activation bridge survives billing.active flipping true (no blank flash)", async () => {
		// The activation push both (a) raises the "Setting up your account…" bridge
		// and (b) flips billing.active true server-side. If the bridge lives behind
		// the `needsSubscription = !billing.active` gate, (b) unmounts it before the
		// wizard navigates → a blank panel flashes. The bridge must persist.
		let billingActive = false;
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") {
				return billingActive
					? {
							tier: "starter",
							active: true,
							trial_days_remaining: 0,
							subscription: null,
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
			if (url === "/billing/config") {
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
			}
			if (url === "/me") {
				return { user: ME };
			}
			if (url === "/onboarding/status") {
				return { next_step: "tools", enabled: true };
			}
			throw new Error(`unexpected GET ${url}`);
		});

		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: vi.fn() },
		}));

		// no-op onActivated: mirrors the wizard NOT yet navigating, so the steady
		// bridge must hold on its own instead of relying on an unmount.
		const onActivated = vi.fn();
		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false } },
		});
		render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter>
							<BillingPage hideHeading onActivated={onActivated} />
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);

		await waitFor(() => expect(channelHandlers.subscription_activated).toBeDefined());
		await act(async () => {
			await Promise.resolve();
			await Promise.resolve();
		});

		// Server flips the subscription active; mirror it so the handler's refetch
		// returns active and needsSubscription goes false mid-activation.
		billingActive = true;
		await act(async () => {
			channelHandlers.subscription_activated!({
				tier: "starter",
				status: "trialing",
				subscription_id: "sub_1",
			});
			await Promise.resolve();
		});

		await waitFor(() => expect(onActivated).toHaveBeenCalled());
		// Until the wizard navigates, the steady bridge must still be on screen —
		// not a blank panel.
		expect(screen.getByText(/Setting up your account/iu)).toBeInTheDocument();
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
			if (url === "/billing/config") {
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
			}
			if (url === "/me") {
				return { user: ME };
			}
			if (url === "/onboarding/status") {
				return { next_step: "tools", enabled: true };
			}
			throw new Error(`unexpected GET ${url}`);
		});

		initializePaddleMock.mockImplementation(async () => ({
			Checkout: { open: vi.fn(), close: vi.fn() },
		}));

		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false } },
		});
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

		await waitFor(() => expect(channelHandlers.subscription_activated).toBeDefined());

		billingActive = true;
		await act(async () => {
			channelHandlers.subscription_activated!({
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
			if (url === "/billing/status") {
				return {
					tier: "free",
					active: false,
					trial_days_remaining: 0,
					subscription: null,
					caps: {},
				};
			}
			if (url === "/billing/config") {
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
			}
			if (url === "/me") {
				return { user: ME };
			}
			if (url === "/onboarding/status") {
				return { next_step: "done", enabled: true };
			}
			throw new Error(`unexpected GET ${url}`);
		});

		let captured: ((event: { name: string; data?: unknown }) => void) | undefined;
		initializePaddleMock.mockImplementation(async (opts: { eventCallback?: typeof captured }) => {
			captured = opts.eventCallback;
			return { Checkout: { open: vi.fn(), close: vi.fn() } };
		});

		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false } },
		});
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
			captured!({
				name: "checkout.completed",
				data: { transaction_id: "txn_up_1" },
			});
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

	it("subscribed flow: Cancel button opens the cancel dialog (no portal redirect)", async () => {
		initializePaddleMock.mockResolvedValue({
			Checkout: { open: vi.fn(), close: vi.fn() },
		});

		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") {
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
			}
			if (url === "/billing/config") {
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
			}
			if (url === "/me") {
				return { user: ME };
			}
			if (url === "/billing/subscription") {
				return {
					next_billed_at: "2026-07-01T00:00:00Z",
					scheduled_change: null,
				};
			}
			if (url === "/billing/transactions") {
				return { payment_method: null, transactions: [] };
			}
			throw new Error(`unexpected GET ${url}`);
		});

		renderBilling({ inline: false });

		const cancelButton = await screen.findByRole("button", {
			name: /cancel subscription/iu,
		});
		await act(async () => {
			cancelButton.click();
		});

		await screen.findByRole("dialog", { name: /cancel subscription/iu });
		expect(screen.getByRole("button", { name: /cancel at period end/iu })).toBeInTheDocument();
	});

	it("subscribed flow: Change plan button opens PlanChangePanel inline", async () => {
		initializePaddleMock.mockResolvedValue({
			Checkout: { open: vi.fn(), close: vi.fn() },
		});

		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") {
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
			}
			if (url === "/billing/config") {
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
			}
			if (url === "/me") {
				return { user: ME };
			}
			if (url === "/billing/subscription") {
				return {
					next_billed_at: "2026-07-01T00:00:00Z",
					scheduled_change: null,
				};
			}
			if (url === "/billing/transactions") {
				return { payment_method: null, transactions: [] };
			}
			throw new Error(`unexpected GET ${url}`);
		});

		renderBilling({ inline: false });

		const changeButton = await screen.findByRole("button", {
			name: /change plan/iu,
		});
		await act(async () => {
			changeButton.click();
		});

		await screen.findByRole("region", { name: /change plan/iu });
	});
});

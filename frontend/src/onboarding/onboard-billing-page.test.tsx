import React from "react";
import { describe, it, expect, vi, beforeEach } from "vitest";
import { act, render, screen, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { MemoryRouter, Routes, Route } from "react-router";
import { ThemeProvider } from "../theme/theme-provider";
import { AuthContext, type AuthAdapter } from "../auth/auth-context";

// Capture the Paddle eventCallback so the test can drive it (or refuse to).
let capturedEventCallback: ((event: { name: string; data?: unknown }) => void) | undefined;

// Counter for tools-page mounts. If onActivated fires twice (replace: true),
// react-router would re-mount the tools route — counter goes to 2.
let toolsPageMounts = 0;
function ToolsPageProbe() {
	React.useEffect(() => {
		toolsPageMounts += 1;
	}, []);
	return <div data-testid="tools-page" />;
}

// Captured Phoenix channel handlers — drive subscription_activated from tests.
// Hoisted so vi.mock factory can reference them. Constructor function (not
// arrow) so `new Socket(...)` works with vi.fn's Mock semantics.
const { channelHandlers, socketChannel, socketConnect, socketDisconnect, socketCtor } = vi.hoisted(
	() => {
		const channelHandlers: Record<string, (payload: unknown) => void> = {};
		const channelMock = {
			on: (event: string, cb: (payload: unknown) => void) => {
				channelHandlers[event] = cb;
			},
			join: () => ({ receive: () => ({}) }),
		};
		const socketChannel = vi.fn(() => channelMock);
		const socketConnect = vi.fn();
		const socketDisconnect = vi.fn();
		const socketCtor = vi.fn(function MockSocket(this: object, ..._args: unknown[]) {
			Object.assign(this, {
				connect: socketConnect,
				channel: socketChannel,
				disconnect: socketDisconnect,
			});
		});
		return { channelHandlers, socketChannel, socketConnect, socketDisconnect, socketCtor };
	},
);
vi.mock("phoenix", () => ({ Socket: socketCtor }));

vi.mock("@paddle/paddle-js", () => ({
	initializePaddle: vi.fn(async (opts: { eventCallback?: typeof capturedEventCallback }) => {
		capturedEventCallback = opts.eventCallback;
		return {
			Checkout: { open: vi.fn(), close: vi.fn() },
		};
	}),
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

const { get, post, patch, del } = vi.hoisted(() => ({
	get: vi.fn(),
	post: vi.fn(),
	patch: vi.fn(),
	del: vi.fn(),
}));
vi.mock("../api/client", () => ({
	api: { get, post, patch, del },
	setTokenGetter: vi.fn(),
}));

// Import AFTER mocks so the hooks resolve against the mocked client.
import OnboardBillingPage from "./onboard-billing-page";

const authAdapter: AuthAdapter = {
	isLoaded: true,
	isSignedIn: true,
	user: { email: "u@example.com" },
	getToken: async () => "tok-test",
	logout: async () => {},
	hasBuiltInUI: false,
};

function renderOnboardBilling() {
	const qc = new QueryClient({
		defaultOptions: { queries: { retry: false, gcTime: 0 } },
	});
	return render(
		<QueryClientProvider client={qc}>
			<AuthContext.Provider value={authAdapter}>
				<ThemeProvider>
					<MemoryRouter initialEntries={["/onboard/billing"]}>
						<Routes>
							<Route path="/onboard/billing" element={<OnboardBillingPage />} />
							<Route path="/onboard/tools" element={<ToolsPageProbe />} />
							<Route path="/onboard/vault" element={<div data-testid="vault-page" />} />
							<Route path="/" element={<div data-testid="home-page" />} />
						</Routes>
					</MemoryRouter>
				</ThemeProvider>
			</AuthContext.Provider>
		</QueryClientProvider>,
	);
}

const STATUS_BILLING = {
	enabled: true,
	next_step: "billing" as const,
	subscription_ok: false,
	terms_ok: true,
	steps: ["agreement", "billing", "tools", "vault"] as const,
	actions: [],
	vault_count: 0,
};

const STATUS_TOOLS = {
	...STATUS_BILLING,
	next_step: "tools" as const,
	subscription_ok: true,
};

const BILLING_INACTIVE = {
	tier: "free",
	active: false,
	trial_days_remaining: 0,
	subscription: null,
	caps: {
		obsidian_connections: null,
		mcp_connections: null,
		api_write_enabled: false,
		vaults: null,
	},
};

const BILLING_ACTIVE = {
	tier: "starter",
	active: true,
	trial_days_remaining: 7,
	subscription: { status: "trialing", tier: "starter", current_period_end: "2026-07-01" },
	caps: {
		obsidian_connections: null,
		mcp_connections: null,
		api_write_enabled: true,
		vaults: null,
	},
};

const BILLING_CONFIG = {
	client_token: "tok",
	environment: "sandbox",
	price_ids: {
		starter: { monthly: "p1", annual: "p2" },
		pro: { monthly: "p3", annual: "p4" },
	},
	customer_email: "u@example.com",
	custom_data: { user_id: 1 },
	vaults_cap: null,
};

const ME = { id: 42, email: "u@example.com", role: "member" as const, display_name: null };

async function flush() {
	await act(async () => {
		await Promise.resolve();
		await Promise.resolve();
		await Promise.resolve();
	});
}

describe("OnboardBillingPage — push activation", () => {
	beforeEach(() => {
		capturedEventCallback = undefined;
		toolsPageMounts = 0;
		get.mockReset();
		post.mockReset();
		patch.mockReset();
		del.mockReset();
		socketCtor.mockClear();
		socketChannel.mockClear();
		socketConnect.mockClear();
		socketDisconnect.mockClear();
		for (const k of Object.keys(channelHandlers)) delete channelHandlers[k];
	});

	it("navigates user off the billing page when subscription_activated lands on the channel", async () => {
		// Initial: user lands on billing page, sub inactive.
		let billingActive = false;
		let nextStep: "billing" | "tools" = "billing";
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") return billingActive ? BILLING_ACTIVE : BILLING_INACTIVE;
			if (url === "/billing/config") return BILLING_CONFIG;
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") {
				return nextStep === "tools" ? STATUS_TOOLS : STATUS_BILLING;
			}
			throw new Error(`unexpected GET ${url}`);
		});

		renderOnboardBilling();

		// Plan picker visible — both "Start free trial" buttons present.
		await waitFor(() =>
			expect(screen.getAllByRole("button", { name: /start free trial/i }).length).toBeGreaterThan(
				0,
			),
		);

		// Channel must be wired by now.
		await waitFor(() => expect(channelHandlers["subscription_activated"]).toBeDefined());

		// Simulate the post-Start-trial flow: payment initiates inside Paddle's
		// inline frame (which here is mocked — we just drive the event directly).
		await waitFor(() => expect(capturedEventCallback).toBeDefined());
		await act(async () => {
			capturedEventCallback!({
				name: "checkout.payment.initiated",
				data: { transaction_id: "txn_push_1" },
			});
		});

		// Backend flips active and webhook lands → channel fires.
		billingActive = true;
		nextStep = "tools";
		await act(async () => {
			channelHandlers["subscription_activated"]!({
				tier: "starter",
				status: "trialing",
				subscription_id: "sub_1",
			});
			await Promise.resolve();
		});

		await waitFor(() => expect(screen.getByTestId("tools-page")).toBeInTheDocument());
		expect(toolsPageMounts).toBe(1);
	});

	it("fires onActivated exactly once even if channel fires subscription_activated twice", async () => {
		let billingActive = false;
		let nextStep: "billing" | "tools" = "billing";
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") return billingActive ? BILLING_ACTIVE : BILLING_INACTIVE;
			if (url === "/billing/config") return BILLING_CONFIG;
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") {
				return nextStep === "tools" ? STATUS_TOOLS : STATUS_BILLING;
			}
			throw new Error(`unexpected GET ${url}`);
		});

		renderOnboardBilling();

		await waitFor(() =>
			expect(screen.getAllByRole("button", { name: /start free trial/i }).length).toBeGreaterThan(
				0,
			),
		);
		await waitFor(() => expect(channelHandlers["subscription_activated"]).toBeDefined());
		await waitFor(() => expect(capturedEventCallback).toBeDefined());
		await act(async () => {
			capturedEventCallback!({
				name: "checkout.payment.initiated",
				data: { transaction_id: "txn_guarantee_42" },
			});
		});

		billingActive = true;
		nextStep = "tools";

		// First broadcast.
		await act(async () => {
			channelHandlers["subscription_activated"]!({
				tier: "starter",
				status: "trialing",
				subscription_id: "sub_1",
			});
			await Promise.resolve();
		});

		await waitFor(() => expect(screen.getByTestId("tools-page")).toBeInTheDocument());
		expect(toolsPageMounts).toBe(1);

		// Second broadcast (e.g. subscription.activated after subscription.created)
		// must NOT trigger a second navigation.
		await act(async () => {
			channelHandlers["subscription_activated"]!({
				tier: "starter",
				status: "active",
				subscription_id: "sub_1",
			});
			await flush();
		});

		expect(toolsPageMounts).toBe(1);
	});

	it("navigates immediately if cached onboarding status is already past billing", async () => {
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") return BILLING_ACTIVE;
			if (url === "/billing/config") return BILLING_CONFIG;
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") return STATUS_TOOLS;
			throw new Error(`unexpected GET ${url}`);
		});

		const qc = new QueryClient({
			defaultOptions: { queries: { retry: false, gcTime: 0 } },
		});
		// Pre-warm cache: user already advanced past billing in another tab.
		qc.setQueryData(["onboarding", "status"], STATUS_TOOLS);

		render(
			<QueryClientProvider client={qc}>
				<AuthContext.Provider value={authAdapter}>
					<ThemeProvider>
						<MemoryRouter initialEntries={["/onboard/billing"]}>
							<Routes>
								<Route path="/onboard/billing" element={<OnboardBillingPage />} />
								<Route path="/onboard/tools" element={<ToolsPageProbe />} />
								<Route path="/" element={<div data-testid="home-page" />} />
							</Routes>
						</MemoryRouter>
					</ThemeProvider>
				</AuthContext.Provider>
			</QueryClientProvider>,
		);

		// Should redirect on mount cache check, NOT wait on the channel.
		await waitFor(() => expect(screen.getByTestId("tools-page")).toBeInTheDocument());
		expect(toolsPageMounts).toBe(1);
	});

	it("returns from inline Paddle frame back to plan picker on CHECKOUT_PAYMENT_FAILED", async () => {
		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") return BILLING_INACTIVE;
			if (url === "/billing/config") return BILLING_CONFIG;
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") return STATUS_BILLING;
			throw new Error(`unexpected GET ${url}`);
		});

		const { container } = renderOnboardBilling();

		await waitFor(() =>
			expect(screen.getAllByRole("button", { name: /start free trial/i }).length).toBeGreaterThan(
				0,
			),
		);
		await waitFor(() => expect(capturedEventCallback).toBeDefined());

		// Click "Start free trial" — inline mount target replaces plan cards.
		await act(async () => {
			screen.getAllByRole("button", { name: /start free trial/i })[0]!.click();
			await Promise.resolve();
		});
		expect(container.querySelector(".paddle-checkout")).not.toBeNull();

		// Payment fails — plan picker comes back.
		await act(async () => {
			capturedEventCallback!({ name: "checkout.payment.failed" });
		});

		await waitFor(() => expect(container.querySelector(".paddle-checkout")).toBeNull());
		expect(screen.getAllByRole("button", { name: /start free trial/i }).length).toBeGreaterThan(0);
	});
});

describe("OnboardBillingPage — Free tier CTA", () => {
	beforeEach(() => {
		capturedEventCallback = undefined;
		toolsPageMounts = 0;
		get.mockReset();
		post.mockReset();
		patch.mockReset();
		del.mockReset();
		socketCtor.mockClear();
		socketChannel.mockClear();
		socketConnect.mockClear();
		socketDisconnect.mockClear();
		for (const k of Object.keys(channelHandlers)) delete channelHandlers[k];

		get.mockImplementation(async (url: string) => {
			if (url === "/billing/status") return BILLING_INACTIVE;
			if (url === "/billing/config") return BILLING_CONFIG;
			if (url === "/me") return { user: ME };
			if (url === "/onboarding/status") return STATUS_BILLING;
			throw new Error(`unexpected GET ${url}`);
		});
	});

	it("renders 'Continue with Free' button with subtitle", async () => {
		renderOnboardBilling();

		const btn = await screen.findByRole("button", { name: /continue with free/i });
		expect(btn).toBeInTheDocument();
		expect(screen.getByText(/10k notes · 1 vault · markdown only/i)).toBeInTheDocument();
	});

	it("calls POST /api/onboarding/accept_free_tier and navigates to /onboard/vault", async () => {
		post.mockImplementation(async (url: string) => {
			if (url === "/onboarding/accept_free_tier") {
				return { ok: true, next_step: "vault" };
			}
			throw new Error(`unexpected POST ${url}`);
		});

		renderOnboardBilling();

		const btn = await screen.findByRole("button", { name: /continue with free/i });
		await act(async () => {
			btn.click();
			await Promise.resolve();
		});

		await waitFor(() => expect(post).toHaveBeenCalledWith("/onboarding/accept_free_tier"));
		await waitFor(() => expect(screen.getByTestId("vault-page")).toBeInTheDocument());
	});
});

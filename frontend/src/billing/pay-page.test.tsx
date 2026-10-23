import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import PayPage from "./pay-page";

const { initializePaddle, get } = vi.hoisted(() => ({
	initializePaddle: vi.fn(),
	get: vi.fn(),
}));
vi.mock("@paddle/paddle-js", () => ({
	initializePaddle,
	CheckoutEventNames: {
		CHECKOUT_LOADED: "checkout.loaded",
		CHECKOUT_CLOSED: "checkout.closed",
		CHECKOUT_COMPLETED: "checkout.completed",
		CHECKOUT_ERROR: "checkout.error",
	},
}));
vi.mock("../api/client", () => ({ api: { get } }));
vi.mock("../theme/theme-toggle", () => ({
	default: () => <button type="button">theme</button>,
}));

const TXN = "txn_01h2b0qpjc0xt8k5aw6nsdec4p";

function renderAt(url: string) {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter initialEntries={[url]}>
				<PayPage />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("PayPage (Paddle default payment link)", () => {
	const open = vi.fn();
	const close = vi.fn();
	let emit: (event: { name: string; data?: unknown }) => void = () => undefined;

	beforeEach(() => {
		open.mockReset();
		close.mockReset();
		get.mockReset();
		initializePaddle.mockReset();
		get.mockResolvedValue({ client_token: "live_tok", environment: "production" });
		initializePaddle.mockImplementation(async (opts: { eventCallback: typeof emit }) => {
			emit = opts.eventCallback;
			return { Checkout: { open, close } };
		});
	});

	it("opens the overlay checkout for the ?_ptxn transaction", async () => {
		renderAt(`/pay?_ptxn=${TXN}`);
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		expect(get).toHaveBeenCalledWith("/billing/paddle-client");
		expect(initializePaddle).toHaveBeenCalledWith(
			expect.objectContaining({ token: "live_tok", environment: "production" }),
		);
		expect(open).toHaveBeenCalledWith(
			expect.objectContaining({
				transactionId: TXN,
				settings: expect.objectContaining({ displayMode: "overlay" }),
			}),
		);
	});

	it.each(["/pay", "/pay?_ptxn=", "/pay?_ptxn=sub_01h2b0qpjc0xt8k5aw6nsdec4p", "/pay?_ptxn=txn_x"])(
		"says the link is invalid, with help, and never boots Paddle for %s",
		async (url) => {
			renderAt(url);
			expect(
				await screen.findByRole("heading", { name: "This payment link is invalid or has expired" }),
			).toBeInTheDocument();
			expect(screen.getByRole("link", { name: "support@engram.page" })).toHaveAttribute(
				"href",
				"mailto:support@engram.page",
			);
			expect(screen.getByRole("link", { name: "Go to Engram" })).toHaveAttribute("href", "/");
			expect(initializePaddle).not.toHaveBeenCalled();
		},
	);

	it("shows an error instead of spinning when Paddle.js fails to load", async () => {
		initializePaddle.mockImplementation(async () => undefined);
		renderAt(`/pay?_ptxn=${TXN}`);
		expect(await screen.findByRole("alert")).toBeInTheDocument();
		expect(open).not.toHaveBeenCalled();
	});

	it("offers to reopen the same transaction when the buyer closes the overlay", async () => {
		renderAt(`/pay?_ptxn=${TXN}`);
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		act(() => emit({ name: "checkout.closed", data: { status: "ready" } }));
		expect(screen.getByRole("heading", { name: "Checkout closed" })).toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: "Reopen checkout" }));
		expect(open).toHaveBeenCalledTimes(2);
		expect(open).toHaveBeenLastCalledWith(expect.objectContaining({ transactionId: TXN }));
	});

	it("confirms the payment and links into the app on completion, even after the overlay closes", async () => {
		renderAt(`/pay?_ptxn=${TXN}`);
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		act(() => emit({ name: "checkout.completed", data: { status: "completed" } }));
		act(() => emit({ name: "checkout.closed", data: { status: "completed" } }));
		expect(screen.getByRole("heading", { name: "Payment received" })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "Open Engram" })).toHaveAttribute("href", "/");
	});

	it("says so plainly when the transaction was already paid", async () => {
		renderAt(`/pay?_ptxn=${TXN}`);
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		act(() => emit({ name: "checkout.loaded", data: { status: "completed" } }));
		// Our own close fires checkout.closed; that must not offer a reopen.
		act(() => emit({ name: "checkout.closed", data: { status: "completed" } }));
		expect(
			screen.getByRole("heading", { name: "This payment has already been made" }),
		).toBeInTheDocument();
		expect(close).toHaveBeenCalled();
	});

	it("treats an API error for a dead transaction as an invalid link and closes the overlay", async () => {
		renderAt(`/pay?_ptxn=${TXN}`);
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		act(() =>
			emit({
				name: "checkout.error",
				type: "api_error",
				code: "transaction_not_ready_cannot_process_payment",
			} as never),
		);
		expect(
			screen.getByRole("heading", { name: "This payment link is invalid or has expired" }),
		).toBeInTheDocument();
		expect(close).toHaveBeenCalled();
	});

	it("offers Try again on a transient checkout error, reopening the same transaction", async () => {
		renderAt(`/pay?_ptxn=${TXN}`);
		await waitFor(() => expect(open).toHaveBeenCalledTimes(1));
		act(() => emit({ name: "checkout.error", type: "front-end_error", code: "unknown" } as never));
		expect(screen.getByRole("alert")).toBeInTheDocument();
		expect(close).toHaveBeenCalled();
		fireEvent.click(screen.getByRole("button", { name: "Try again" }));
		expect(open).toHaveBeenCalledTimes(2);
		expect(open).toHaveBeenLastCalledWith(expect.objectContaining({ transactionId: TXN }));
	});
});

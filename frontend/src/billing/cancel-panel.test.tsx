import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { SubscriptionDetail } from "../api/queries";
import CancelPanel from "./cancel-panel";

const { post } = vi.hoisted(() => ({ post: vi.fn() }));
vi.mock("../api/client", () => ({
	api: { get: vi.fn(), post, patch: vi.fn(), del: vi.fn() },
	setTokenGetter: vi.fn(),
}));

let qc: QueryClient;

beforeEach(() => {
	post.mockReset();
	qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } });
});

afterEach(() => {
	qc.clear();
});

function Wrapper({ children }: { children: ReactNode }) {
	return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
}

function detail(overrides: Partial<SubscriptionDetail> = {}): SubscriptionDetail {
	return {
		next_billed_at: "2026-07-01T00:00:00Z",
		amount: "14.00",
		currency: "USD",
		billing_cycle: { interval: "month", frequency: 1 },
		scheduled_change: null,
		...overrides,
	};
}

describe("CancelPanel", () => {
	it("renders Pro tier copy for a pro subscriber", () => {
		render(<CancelPanel detail={detail()} tier="pro" onClose={vi.fn()} />, { wrapper: Wrapper });
		expect(screen.getByText(/keep your pro plan/iu)).toBeInTheDocument();
		expect(screen.getByText(/2026/u)).toBeInTheDocument();
	});

	it("renders Starter tier copy for a starter subscriber (no Pro mislabel)", () => {
		render(<CancelPanel detail={detail()} tier="starter" onClose={vi.fn()} />, {
			wrapper: Wrapper,
		});
		expect(screen.getByText(/keep your starter plan/iu)).toBeInTheDocument();
		expect(screen.queryByText(/keep your pro plan/iu)).not.toBeInTheDocument();
	});

	it("confirm calls cancel mutation and onClose on success", async () => {
		post.mockResolvedValue({ scheduled_change: { effective_at: "2026-07-01T00:00:00Z" } });
		const onClose = vi.fn();

		render(<CancelPanel detail={detail()} tier="pro" onClose={onClose} />, { wrapper: Wrapper });
		fireEvent.click(screen.getByRole("button", { name: /cancel at period end/iu }));

		await waitFor(() => expect(onClose).toHaveBeenCalled());
		expect(post).toHaveBeenCalledWith("/billing/cancel-subscription");
	});

	it("keep button calls onClose without firing the mutation", () => {
		const onClose = vi.fn();
		render(<CancelPanel detail={detail()} tier="pro" onClose={onClose} />, { wrapper: Wrapper });

		fireEvent.click(screen.getByRole("button", { name: /keep my subscription/iu }));

		expect(post).not.toHaveBeenCalled();
		expect(onClose).toHaveBeenCalled();
	});

	it("falls back to generic copy when next_billed_at is null", () => {
		render(<CancelPanel detail={detail({ next_billed_at: null })} tier="pro" onClose={vi.fn()} />, {
			wrapper: Wrapper,
		});
		expect(
			screen.getByText(/keep paid access through the end of your current billing period/iu),
		).toBeInTheDocument();
	});
});

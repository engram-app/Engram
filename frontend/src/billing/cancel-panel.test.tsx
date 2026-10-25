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
		fireEvent.click(screen.getByRole("radio", { name: /switched to another tool/iu }));
		fireEvent.change(screen.getByLabelText(/tell us more/iu), { target: { value: "Notion" } });
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

	it("sends the reason once the cancel succeeds", async () => {
		post.mockResolvedValue({});
		const onClose = vi.fn();
		render(<CancelPanel detail={detail()} tier="pro" onClose={onClose} />, { wrapper: Wrapper });

		fireEvent.click(screen.getByRole("radio", { name: /too expensive/iu }));
		fireEvent.change(screen.getByLabelText(/tell us more/iu), {
			target: { value: "  half the price  " },
		});
		fireEvent.click(screen.getByRole("button", { name: /cancel at period end/iu }));

		await waitFor(() => expect(onClose).toHaveBeenCalled());
		expect(post).toHaveBeenCalledWith("/feedback", {
			kind: "cancel",
			reason: "too_expensive",
			detail: "half the price",
		});
		expect(post).toHaveBeenCalledWith("/billing/cancel-subscription");
	});

	it("cancels with no reason and no typed sentence, filed as in_app_no_reason", async () => {
		post.mockResolvedValue({});
		const onClose = vi.fn();
		render(<CancelPanel detail={detail()} tier="pro" onClose={onClose} />, { wrapper: Wrapper });
		const cancelButton = screen.getByRole("button", { name: /cancel at period end/iu });

		expect(cancelButton).toBeEnabled();
		fireEvent.click(cancelButton);

		await waitFor(() => expect(onClose).toHaveBeenCalled());
		expect(post).toHaveBeenCalledWith("/billing/cancel-subscription");
		// Filed now, so the marker's later check finds it and files no
		// `portal_no_reason` (that label is for real portal cancels).
		expect(post).toHaveBeenCalledWith("/feedback", {
			kind: "cancel",
			reason: "in_app_no_reason",
			detail: "",
		});
	});

	it("sends typed text with no picked reason as other", async () => {
		post.mockResolvedValue({});
		const onClose = vi.fn();
		render(<CancelPanel detail={detail()} tier="pro" onClose={onClose} />, { wrapper: Wrapper });

		fireEvent.change(screen.getByLabelText(/tell us more/iu), { target: { value: " too slow " } });
		fireEvent.click(screen.getByRole("button", { name: /cancel at period end/iu }));

		await waitFor(() => expect(onClose).toHaveBeenCalled());
		expect(post).toHaveBeenCalledWith("/feedback", {
			kind: "cancel",
			reason: "other",
			detail: "too slow",
		});
	});

	it("sends a picked reason without requiring a sentence", async () => {
		post.mockResolvedValue({});
		const onClose = vi.fn();
		render(<CancelPanel detail={detail()} tier="pro" onClose={onClose} />, { wrapper: Wrapper });

		fireEvent.click(screen.getByRole("radio", { name: /too expensive/iu }));
		fireEvent.click(screen.getByRole("button", { name: /cancel at period end/iu }));

		await waitFor(() => expect(onClose).toHaveBeenCalled());
		expect(post).toHaveBeenCalledWith("/feedback", {
			kind: "cancel",
			reason: "too_expensive",
			detail: "",
		});
	});

	it("labels the reason question optional", () => {
		render(<CancelPanel detail={detail()} tier="pro" onClose={vi.fn()} />, { wrapper: Wrapper });
		expect(screen.getByText(/why are you canceling\? \(optional\)/iu)).toBeInTheDocument();
	});

	it("sends no reason when the cancel itself fails", async () => {
		post.mockImplementation((path: string) =>
			path === "/billing/cancel-subscription"
				? Promise.reject(new Error("paddle down"))
				: Promise.resolve({}),
		);
		render(<CancelPanel detail={detail()} tier="pro" onClose={vi.fn()} />, { wrapper: Wrapper });

		fireEvent.click(screen.getByRole("radio", { name: /too expensive/iu }));
		fireEvent.change(screen.getByLabelText(/tell us more/iu), { target: { value: "x" } });
		fireEvent.click(screen.getByRole("button", { name: /cancel at period end/iu }));

		await waitFor(() => expect(post).toHaveBeenCalledWith("/billing/cancel-subscription"));
		await new Promise((r) => setTimeout(r, 0));
		expect(post).not.toHaveBeenCalledWith("/feedback", expect.anything());
	});

	it("still cancels when the feedback call fails", async () => {
		post.mockImplementation((path: string) =>
			path === "/feedback" ? Promise.reject(new Error("boom")) : Promise.resolve({}),
		);
		const onClose = vi.fn();
		render(<CancelPanel detail={detail()} tier="pro" onClose={onClose} />, { wrapper: Wrapper });

		fireEvent.click(screen.getByRole("radio", { name: /not using it enough/iu }));
		fireEvent.change(screen.getByLabelText(/tell us more/iu), { target: { value: "busy" } });
		fireEvent.click(screen.getByRole("button", { name: /cancel at period end/iu }));

		await waitFor(() => expect(onClose).toHaveBeenCalled());
		expect(post).toHaveBeenCalledWith("/billing/cancel-subscription");
	});
});

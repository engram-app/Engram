import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { BillingTransaction } from "../api/queries";
import BillingHistoryTable from "./billing-history-table";

const txns: BillingTransaction[] = [
	{
		id: "txn_2",
		billed_at: "2026-05-27T07:00:00Z",
		amount: "2000",
		currency: "USD",
		status: "completed",
		invoice_id: "inv_2",
		invoice_available: true,
	},
	{
		id: "txn_1",
		billed_at: "2026-04-27T07:00:00Z",
		amount: "2000",
		currency: "USD",
		status: "past_due",
		invoice_id: "inv_1",
		invoice_available: true,
	},
];

describe("BillingHistoryTable", () => {
	it("renders a row per transaction with formatted amount and status", () => {
		render(<BillingHistoryTable transactions={txns} onDownload={() => {}} />);
		expect(screen.getAllByText("$20.00")).toHaveLength(2);
		expect(screen.getByText(/completed/iu)).toBeInTheDocument();
		expect(screen.getByText(/past due/iu)).toBeInTheDocument();
	});

	it("shows an empty state when there are no transactions", () => {
		render(<BillingHistoryTable transactions={[]} onDownload={() => {}} />);
		expect(screen.getByText(/no transactions/iu)).toBeInTheDocument();
	});

	it("calls onDownload with the transaction id", async () => {
		const onDownload = vi.fn();
		render(<BillingHistoryTable transactions={txns} onDownload={onDownload} />);
		const [firstDownload] = screen.getAllByRole("button", { name: /download/iu });
		fireEvent.click(firstDownload as HTMLElement);
		expect(onDownload).toHaveBeenCalledWith("txn_2");
	});

	// Paddle has no invoice for a $0 transaction (every trial start), so a
	// Download there could only fail.
	it("renders no Download for a row without an invoice", () => {
		const trial: BillingTransaction = {
			id: "txn_trial",
			billed_at: "2026-10-24T22:20:53Z",
			amount: "0",
			currency: "USD",
			status: "completed",
			invoice_id: null,
			invoice_available: false,
		};
		render(<BillingHistoryTable transactions={[trial]} onDownload={() => {}} />);
		expect(screen.queryByRole("button", { name: /download/iu })).not.toBeInTheDocument();
		// Same placeholder as the other empty cells, not a blank cell.
		expect(screen.getAllByRole("cell").at(-1)).toHaveTextContent("\u2014");
	});

	// The backend decides (zero-value or not completed means no invoice); an
	// invoice_id alone does not make the PDF available.
	it("renders no Download when the backend says no invoice is available", () => {
		const pastDue: BillingTransaction = {
			id: "txn_due",
			billed_at: "2026-10-24T22:20:53Z",
			amount: "2000",
			currency: "USD",
			status: "past_due",
			invoice_id: "inv_due",
			invoice_available: false,
		};
		render(<BillingHistoryTable transactions={[pastDue]} onDownload={() => {}} />);
		expect(screen.queryByRole("button", { name: /download/iu })).not.toBeInTheDocument();
	});

	// The SPA is promoted separately from the backend, so a new SPA can read a
	// response from a backend that predates invoice_available. Keep Download.
	it("renders Download when the backend omits invoice_available (older backend)", () => {
		const legacy: BillingTransaction = {
			id: "txn_old",
			billed_at: "2026-05-27T07:00:00Z",
			amount: "2000",
			currency: "USD",
			status: "completed",
			invoice_id: "inv_old",
		};
		render(<BillingHistoryTable transactions={[legacy]} onDownload={() => {}} />);
		expect(screen.getByRole("button", { name: /download/iu })).toBeInTheDocument();
	});
});

import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError } from "../api/client";
import { downloadInvoice } from "./download-invoice";

const { get, error } = vi.hoisted(() => ({ get: vi.fn(), error: vi.fn() }));
vi.mock("../api/client", async (importOriginal) => ({
	...(await importOriginal<typeof import("../api/client")>()),
	api: { get },
}));
vi.mock("@/lib/notify", () => ({ notify: { error } }));

const t = (key: string) => key;

describe("downloadInvoice", () => {
	beforeEach(() => {
		get.mockReset();
		error.mockReset();
	});

	it("opens the invoice URL", async () => {
		const open = vi.spyOn(window, "open").mockReturnValue(null);
		get.mockResolvedValue({ url: "https://paddle.test/inv.pdf" });
		await downloadInvoice("txn_2", t);
		expect(get).toHaveBeenCalledWith("/billing/transactions/txn_2/invoice");
		expect(open).toHaveBeenCalledWith("https://paddle.test/inv.pdf", "_blank", "noopener");
		expect(error).not.toHaveBeenCalled();
	});

	// The backend answers 404 when Paddle has no invoice for the transaction
	// (a $0 trial start). Retrying cannot help, so the toast must not say so.
	it("says there is no invoice on a 404, without a retry prompt", async () => {
		get.mockRejectedValue(new ApiError(404, "no invoice for this transaction"));
		await downloadInvoice("txn_trial", t);
		expect(error).toHaveBeenCalledWith("No invoice is available for this transaction.");
	});

	it("keeps the retry prompt for other failures", async () => {
		get.mockRejectedValue(new ApiError(502, "payment provider error"));
		await downloadInvoice("txn_2", t);
		expect(error).toHaveBeenCalledWith("Could not fetch that invoice. Please try again.");
	});
});

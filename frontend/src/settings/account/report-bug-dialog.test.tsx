import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ReportBugDialog } from "./report-bug-dialog";

const mutate = vi.fn();
vi.mock("@/api/queries", () => ({
	useReportBug: () => ({ mutate, isPending: false }),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

describe("ReportBugDialog", () => {
	beforeEach(() => mutate.mockReset());

	it("submits the typed description with surface web", () => {
		render(<ReportBugDialog open onOpenChange={() => {}} />);
		fireEvent.change(screen.getByPlaceholderText(/what happened/i), {
			target: { value: "sync stalls" },
		});
		fireEvent.click(screen.getByRole("button", { name: /send report/i }));
		expect(mutate).toHaveBeenCalledWith(
			expect.objectContaining({ description: "sync stalls", surface: "web" }),
			expect.anything(),
		);
	});

	it("disables submit when the description is empty", () => {
		render(<ReportBugDialog open onOpenChange={() => {}} />);
		expect(screen.getByRole("button", { name: /send report/i })).toBeDisabled();
	});
});

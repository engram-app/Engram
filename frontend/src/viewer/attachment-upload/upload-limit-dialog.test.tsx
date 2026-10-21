import { fireEvent, render, screen, within } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import { UploadLimitDialog } from "./upload-limit-dialog";

vi.mock("../../analytics/track", () => ({ track: vi.fn() }));

const MB = 1024 * 1024;
const f = (name: string, size: number) => new File([new Uint8Array(size)], name);
const plans = {
	starter: { max_file_bytes: 200 * MB, attachment_bytes_cap: 10 * 1024 * MB },
	pro: { max_file_bytes: 500 * MB, attachment_bytes_cap: 50 * 1024 * MB },
};

function renderDialog(props: Partial<Parameters<typeof UploadLimitDialog>[0]> = {}) {
	const onClose = vi.fn();
	render(
		<MemoryRouter>
			<UploadLimitDialog
				tooLarge={[]}
				noRoom={[]}
				tier="free"
				limits={{ maxFileBytes: 10 * MB, storageCap: 1024 * MB, usedBytes: 1000 * MB }}
				planLimits={plans}
				billingEnabled
				onClose={onClose}
				{...props}
			/>
		</MemoryRouter>,
	);
	return { onClose };
}

describe("UploadLimitDialog", () => {
	it("a size refusal: heading, the file on its own row, and the plans compared", () => {
		renderDialog({ tooLarge: [f("big.zip", 42 * MB)] });
		expect(screen.getByRole("heading", { level: 1, name: "File too large" })).toBeInTheDocument();
		const dialog = screen.getByRole("dialog");
		expect(dialog).toHaveTextContent("This file is over the 10 MB upload limit on your Free plan.");
		const row = screen.getByText("big.zip").closest("li");
		expect(row).toHaveTextContent("42 MB");
		const plans = within(screen.getByRole("region", { name: "Compare plans" }));
		expect(plans.getByText("Current")).toBeInTheDocument();
		expect(plans.getByText("200 MB")).toBeInTheDocument();
		expect(plans.getByText("500 MB")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Upgrade" })).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "OK" })).not.toBeInTheDocument();
	});

	it("a storage refusal shows usage and storage by plan", () => {
		renderDialog({ noRoom: [f("a.mp4", 50 * MB)] });
		expect(
			screen.getByRole("heading", { level: 1, name: "Not enough storage" }),
		).toBeInTheDocument();
		expect(screen.getByRole("dialog")).toHaveTextContent("1,000 MB of 1 GB");
		expect(screen.getByRole("progressbar", { name: "Storage used" })).toBeInTheDocument();
		const plans = within(screen.getByRole("region", { name: "Compare plans" }));
		expect(plans.getByText("10 GB")).toBeInTheDocument();
		expect(plans.getByText("50 GB")).toBeInTheDocument();
	});

	it("a drop refused for both reasons lists the files with no room too", () => {
		renderDialog({ tooLarge: [f("big.zip", 42 * MB)], noRoom: [f("a.mp4", 5 * MB)] });
		expect(screen.getByRole("heading", { level: 1, name: "File too large" })).toBeInTheDocument();
		expect(screen.getByText("big.zip")).toBeInTheDocument();
		const room = within(screen.getByRole("region", { name: "Not enough storage" }));
		expect(room.getByText("a.mp4")).toBeInTheDocument();
		expect(
			room.getByText("There isn't enough room left on your Free plan for this file."),
		).toBeInTheDocument();
	});

	it("lists several refused files", () => {
		renderDialog({ tooLarge: [f("a.zip", 11 * MB), f("b.zip", 12 * MB)] });
		expect(screen.getByRole("heading", { level: 1, name: "Files too large" })).toBeInTheDocument();
		expect(screen.getByText("a.zip")).toBeInTheDocument();
		expect(screen.getByText("b.zip")).toBeInTheDocument();
	});

	it("a paid plan only sees the plans above it", () => {
		renderDialog({
			tooLarge: [f("big.zip", 300 * MB)],
			tier: "starter",
			limits: { maxFileBytes: 200 * MB, storageCap: null, usedBytes: 0 },
		});
		const plans = within(screen.getByRole("region", { name: "Compare plans" }));
		expect(plans.queryByText("Free")).not.toBeInTheDocument();
		expect(plans.getByText("500 MB")).toBeInTheDocument();
	});

	it("without billing, states the server's limit and offers only OK", () => {
		const { onClose } = renderDialog({ tooLarge: [f("big.zip", 42 * MB)], billingEnabled: false });
		expect(screen.getByRole("dialog")).toHaveTextContent(
			"This file is over this server's 10 MB upload limit.",
		);
		expect(screen.queryByRole("region", { name: "Compare plans" })).not.toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "Upgrade" })).not.toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: "OK" }));
		expect(onClose).toHaveBeenCalled();
	});
});

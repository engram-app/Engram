import { fireEvent, render, screen } from "@testing-library/react";
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
	it("says the file size, the plan's limit, and what each paid plan allows", () => {
		renderDialog({ tooLarge: [f("big.zip", 42 * MB)] });
		const dialog = screen.getByRole("dialog");
		expect(dialog).toHaveTextContent("big.zip is too large to upload");
		expect(dialog).toHaveTextContent("It's 42 MB. Your Free plan uploads files up to 10 MB.");
		expect(dialog).toHaveTextContent("Starter: files up to 200 MB");
		expect(dialog).toHaveTextContent("Pro: files up to 500 MB");
		expect(screen.getByRole("button", { name: "Upgrade" })).toBeInTheDocument();
	});

	it("says storage is full with used and total, and what each plan includes", () => {
		renderDialog({ noRoom: [f("a.mp4", 50 * MB)] });
		const dialog = screen.getByRole("dialog");
		expect(dialog).toHaveTextContent("Not enough storage for a.mp4");
		expect(dialog).toHaveTextContent("You've used 1,000 MB of your Free plan's 1 GB.");
		expect(dialog).toHaveTextContent("Starter: 10 GB of storage");
		expect(dialog).toHaveTextContent("Pro: 50 GB of storage");
	});

	it("lists several refused files", () => {
		renderDialog({ tooLarge: [f("a.zip", 11 * MB), f("b.zip", 12 * MB)] });
		expect(screen.getByRole("dialog")).toHaveTextContent("2 files are too large to upload");
		expect(screen.getByText("a.zip")).toBeInTheDocument();
		expect(screen.getByText("b.zip")).toBeInTheDocument();
	});

	it("without billing, states the server's limit and offers no upgrade", () => {
		renderDialog({ tooLarge: [f("big.zip", 42 * MB)], billingEnabled: false });
		const dialog = screen.getByRole("dialog");
		expect(dialog).toHaveTextContent("This server uploads files up to 10 MB.");
		expect(dialog).not.toHaveTextContent("Starter");
		expect(screen.queryByRole("button", { name: "Upgrade" })).not.toBeInTheDocument();
	});

	it("closes", () => {
		const { onClose } = renderDialog({ tooLarge: [f("big.zip", 42 * MB)] });
		fireEvent.click(screen.getByRole("button", { name: "OK" }));
		expect(onClose).toHaveBeenCalled();
	});
});

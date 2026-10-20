import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, LimitExceededError } from "@/api/client";
import { AttachmentUploadDialog } from "./upload-dialog";

const showUpgrade = vi.fn();
vi.mock("@/billing/upgrade-dialog-provider", () => ({ useUpgradeDialog: () => ({ showUpgrade }) }));
let billingEnabled = true;
vi.mock("@/config-context", () => ({ useConfig: () => ({ billingEnabled }) }));

const mutateAsync = vi.fn();
vi.mock("@/api/queries", () => ({
	useUploadAttachment: () => ({ mutateAsync }),
}));

function file(name: string, type = "text/plain") {
	return new File([new Uint8Array([1, 2, 3])], name, { type });
}

beforeEach(() => {
	mutateAsync.mockReset();
	showUpgrade.mockReset();
	billingEnabled = true;
});

const limit = (reason: string) => new LimitExceededError(reason, null, null, null, null);
const clickUpload = () => fireEvent.click(screen.getByRole("button", { name: /^upload$/iu }));
function renderOne(name = "a.txt") {
	return render(
		<AttachmentUploadDialog initialFiles={[file(name)]} folders={[]} onClose={() => {}} />,
	);
}

describe("AttachmentUploadDialog", () => {
	it("lists the files and uploads each with folder-prefixed path", async () => {
		mutateAsync.mockResolvedValue({ attachment: { id: "x", path: "docs/a.txt" } });
		render(
			<AttachmentUploadDialog
				initialFiles={[file("a.txt")]}
				folders={[{ name: "docs" }]}
				onClose={() => {}}
			/>,
		);
		expect(screen.getByText("a.txt")).toBeInTheDocument();

		// pick folder "docs"
		fireEvent.click(screen.getByRole("option", { name: "docs" }));
		fireEvent.click(screen.getByRole("button", { name: /^upload$/iu }));

		await waitFor(() =>
			expect(mutateAsync).toHaveBeenCalledWith(
				expect.objectContaining({ path: "docs/a.txt", file: expect.any(File) }),
			),
		);
	});

	it("uploads to root when no folder is picked", async () => {
		mutateAsync.mockResolvedValue({ attachment: { id: "x", path: "a.txt" } });
		render(
			<AttachmentUploadDialog initialFiles={[file("a.txt")]} folders={[]} onClose={() => {}} />,
		);
		fireEvent.click(screen.getByRole("button", { name: /^upload$/iu }));
		await waitFor(() =>
			expect(mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ path: "a.txt" })),
		);
	});

	it("seeds the destination from defaultFolder", async () => {
		mutateAsync.mockResolvedValue({ attachment: { id: "x", path: "docs/a.txt" } });
		render(
			<AttachmentUploadDialog
				initialFiles={[file("a.txt")]}
				folders={[{ name: "docs" }]}
				defaultFolder="docs"
				onClose={() => {}}
			/>,
		);
		// No folder interaction — defaultFolder drives the path.
		fireEvent.click(screen.getByRole("button", { name: /^upload$/iu }));
		await waitFor(() =>
			expect(mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ path: "docs/a.txt" })),
		);
	});

	it("selects a folder via keyboard (ArrowDown) on the listbox", async () => {
		mutateAsync.mockResolvedValue({ attachment: { id: "x", path: "docs/a.txt" } });
		render(
			<AttachmentUploadDialog
				initialFiles={[file("a.txt")]}
				folders={[{ name: "docs" }]}
				onClose={() => {}}
			/>,
		);
		// Starts at root (index 0); ArrowDown moves selection to 'docs' (index 1).
		fireEvent.keyDown(screen.getByRole("listbox"), { key: "ArrowDown" });
		fireEvent.click(screen.getByRole("button", { name: /^upload$/iu }));
		await waitFor(() =>
			expect(mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ path: "docs/a.txt" })),
		);
	});

	it("marks a row errored on 415 without blocking the others", async () => {
		mutateAsync
			.mockRejectedValueOnce(new ApiError(415, "extension_not_allowed"))
			.mockResolvedValueOnce({ attachment: { id: "y", path: "b.txt" } });
		render(
			<AttachmentUploadDialog
				initialFiles={[file("a.exe", "application/x-msdownload"), file("b.txt")]}
				folders={[]}
				onClose={() => {}}
			/>,
		);
		fireEvent.click(screen.getByRole("button", { name: /^upload$/iu }));
		await waitFor(() =>
			expect(screen.getByText("Executable files don't sync.")).toBeInTheDocument(),
		);
		expect(mutateAsync).toHaveBeenCalledTimes(2);
	});

	it("shows an upgrade hint on a 402 LimitExceededError", async () => {
		mutateAsync.mockRejectedValue(
			new LimitExceededError("attachments_disabled", "attachments_enabled", false, null, null),
		);
		render(
			<AttachmentUploadDialog initialFiles={[file("a.txt")]} folders={[]} onClose={() => {}} />,
		);
		fireEvent.click(screen.getByRole("button", { name: /^upload$/iu }));
		await waitFor(() => expect(screen.getByText(/upgrade to upload/iu)).toBeInTheDocument());
	});
});

describe("AttachmentUploadDialog failure states", () => {
	it("402 file_too_large says so once and Upgrade opens the upgrade dialog", async () => {
		mutateAsync.mockRejectedValue(limit("file_too_large"));
		renderOne();
		clickUpload();
		expect(await screen.findAllByText("This file is over your plan's size limit.")).toHaveLength(1);
		fireEvent.click(screen.getByRole("button", { name: "Upgrade" }));
		expect(showUpgrade).toHaveBeenCalledWith("file_too_large");
	});

	it("402 attachments_quota_exceeded says the storage is full with Upgrade", async () => {
		mutateAsync.mockRejectedValue(limit("attachments_quota_exceeded"));
		renderOne();
		clickUpload();
		expect(await screen.findByText("Your storage is full.")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "Upgrade" })).toBeInTheDocument();
	});

	it("offers no Upgrade when billing is disabled (self-host)", async () => {
		billingEnabled = false;
		mutateAsync.mockRejectedValue(limit("file_too_large"));
		renderOne();
		clickUpload();
		await screen.findByText("This file is over your plan's size limit.");
		expect(screen.queryByRole("button", { name: "Upgrade" })).toBeNull();
	});

	it("415 has no Upgrade or retry", async () => {
		mutateAsync.mockRejectedValue(new ApiError(415, "extension_not_allowed"));
		renderOne("a.exe");
		clickUpload();
		await screen.findByText("Executable files don't sync.");
		expect(screen.queryByRole("button", { name: "Upgrade" })).toBeNull();
		expect(screen.queryByRole("button", { name: "Try again" })).toBeNull();
	});

	it("shows Waiting to retry on a retry event, not a failure, then clears on success", async () => {
		let finish: (v: unknown) => void = () => {};
		mutateAsync.mockImplementation(({ onRetry }: { onRetry: (e: unknown) => void }) => {
			onRetry(new ApiError(503, "rotation_in_progress", 1));
			onRetry(new TypeError("network"));
			return new Promise((resolve) => {
				finish = resolve;
			});
		});
		renderOne();
		clickUpload();
		expect(await screen.findAllByText("Waiting to retry")).toHaveLength(1);
		expect(screen.queryByText("Upload failed. Try again.")).toBeNull();
		finish({ attachment: {} });
		await waitFor(() => expect(screen.queryByText("Waiting to retry")).toBeNull());
		expect(screen.getByText("Done", { selector: "output" })).toBeInTheDocument();
	});

	it("a terminal network failure says Upload failed with a Try again that resends", async () => {
		mutateAsync
			.mockRejectedValueOnce(new TypeError("network"))
			.mockResolvedValueOnce({ attachment: {} });
		renderOne();
		clickUpload();
		await screen.findByText("Upload failed. Try again.");
		fireEvent.click(screen.getByRole("button", { name: "Try again" }));
		await waitFor(() => expect(screen.queryByText("Upload failed. Try again.")).toBeNull());
		expect(mutateAsync).toHaveBeenCalledTimes(2);
	});

	it("shows a labelled percentage from onProgress, indeterminate before it", async () => {
		let progress: (done: number, total: number) => void = () => {};
		mutateAsync.mockImplementation(
			({ onProgress }: { onProgress: (d: number, t: number) => void }) => {
				progress = onProgress;
				return new Promise(() => {});
			},
		);
		renderOne();
		clickUpload();
		const bar = await screen.findByRole("progressbar", { name: "Uploading a.txt" });
		expect(bar).not.toHaveAttribute("value");
		act(() => progress(1, 4));
		await waitFor(() => expect(bar).toHaveAttribute("value", "25"));
		expect(screen.getByText("25%")).toBeInTheDocument();
	});
});

describe("AttachmentUploadDialog live region", () => {
	it("keeps the progress bar and percent while waiting to retry", async () => {
		mutateAsync.mockImplementation(
			({
				onProgress,
				onRetry,
			}: {
				onProgress: (d: number, t: number) => void;
				onRetry: () => void;
			}) => {
				onProgress(1, 4);
				onRetry();
				return new Promise(() => {});
			},
		);
		renderOne();
		clickUpload();
		await screen.findByText("Waiting to retry");
		expect(screen.getByRole("progressbar", { name: "Uploading a.txt" })).toHaveAttribute(
			"value",
			"25",
		);
		expect(screen.getByText("25%")).toBeInTheDocument();
	});

	it("announces only the status text; the action buttons sit outside the live region", async () => {
		mutateAsync.mockRejectedValue(limit("file_too_large"));
		renderOne();
		clickUpload();
		const upgrade = await screen.findByRole("button", { name: "Upgrade" });
		const status = screen.getByText("This file is over your plan's size limit.").closest("output");
		expect(status).not.toBeNull();
		expect(status).not.toContainElement(upgrade);
	});
});

describe("AttachmentUploadDialog focus", () => {
	it("focuses the folder search box on open", () => {
		render(
			<AttachmentUploadDialog
				initialFiles={[file("a.txt")]}
				folders={[{ name: "docs" }]}
				onClose={() => {}}
			/>,
		);
		expect(screen.getByRole("combobox", { name: "Search folders" })).toHaveFocus();
	});
});

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ApiError, LimitExceededError } from "@/api/client";
import { AttachmentUploadDialog } from "./upload-dialog";

const mutateAsync = vi.fn();
vi.mock("@/api/queries", () => ({
	useUploadAttachment: () => ({ mutateAsync }),
}));
vi.mock("./file-to-base64", () => ({ fileToBase64: () => Promise.resolve("AAAA") }));

function file(name: string, type = "text/plain") {
	return new File([new Uint8Array([1, 2, 3])], name, { type });
}

beforeEach(() => {
	mutateAsync.mockReset();
});

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
				expect.objectContaining({ path: "docs/a.txt", content_base64: "AAAA" }),
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
			.mockRejectedValueOnce(new ApiError(415, "mime_not_allowed"))
			.mockResolvedValueOnce({ attachment: { id: "y", path: "b.txt" } });
		render(
			<AttachmentUploadDialog
				initialFiles={[file("a.exe", "application/x-msdownload"), file("b.txt")]}
				folders={[]}
				onClose={() => {}}
			/>,
		);
		fireEvent.click(screen.getByRole("button", { name: /^upload$/iu }));
		await waitFor(() => expect(screen.getByText(/not allowed/iu)).toBeInTheDocument());
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

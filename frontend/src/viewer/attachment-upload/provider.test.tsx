import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AttachmentUploadProvider, useAttachmentUpload } from "./provider";

const mutateAsync = vi.fn();
vi.mock("@/api/queries", () => ({
	useFolders: () => ({ data: [{ name: "docs" }] }),
	useAttachments: () => ({ data: [{ path: "docs/a.png" }] }),
	useUploadAttachment: () => ({ mutateAsync }),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
vi.mock("./file-to-base64", () => ({ fileToBase64: () => Promise.resolve("AAAA") }));
// Render a sentinel instead of the real dialog so this test stays unit-scoped.
vi.mock("./upload-dialog", () => ({
	AttachmentUploadDialog: ({ initialFiles }: { initialFiles: File[] }) => (
		<div data-testid="dialog">{initialFiles.map((f) => f.name).join(",")}</div>
	),
}));
function TriggerButton() {
	const { openUpload } = useAttachmentUpload();
	return (
		<button type="button" onClick={() => openUpload([new File(["x"], "fromButton.txt")])}>
			open
		</button>
	);
}

function fileDragEvent(type: string, withFiles: boolean) {
	const ev = new Event(type, { bubbles: true, cancelable: true }) as unknown as DragEvent;
	Object.defineProperty(ev, "dataTransfer", {
		value: {
			types: withFiles ? ["Files"] : ["text/plain"],
			files: withFiles ? [new File(["y"], "dropped.txt")] : [],
		},
	});
	return ev;
}

beforeEach(() => {
	vi.clearAllMocks();
});

describe("AttachmentUploadProvider", () => {
	it("opens the dialog when openUpload is called with files", async () => {
		render(
			<AttachmentUploadProvider>
				<TriggerButton />
			</AttachmentUploadProvider>,
		);
		fireEvent.click(screen.getByText("open"));
		await waitFor(() => expect(screen.getByTestId("dialog")).toHaveTextContent("fromButton.txt"));
	});
});

describe("AttachmentUploadProvider drops", () => {
	it("never opens the dialog for a dropped file; it blocks the browser opening it", () => {
		render(
			<AttachmentUploadProvider>
				<span data-testid="outside">elsewhere</span>
			</AttachmentUploadProvider>,
		);
		const ev = fileDragEvent("drop", true);
		act(() => {
			screen.getByTestId("outside").dispatchEvent(ev);
		});
		expect(screen.queryByTestId("dialog")).toBeNull();
		expect(ev.defaultPrevented).toBe(true);
	});

	it("shows 'not allowed' for a file dragged over a non-target, and leaves targets alone", () => {
		render(
			<AttachmentUploadProvider>
				<span data-testid="outside">elsewhere</span>
				<div data-file-drop>
					<span data-testid="target">here</span>
				</div>
			</AttachmentUploadProvider>,
		);
		const out = fileDragEvent("dragover", true);
		act(() => {
			screen.getByTestId("outside").dispatchEvent(out);
		});
		expect(out.defaultPrevented).toBe(true);
		const over = fileDragEvent("dragover", true);
		act(() => {
			screen.getByTestId("target").dispatchEvent(over);
		});
		expect(over.defaultPrevented).toBe(false);
	});

	it("ignores internal (non-file) drags", () => {
		render(
			<AttachmentUploadProvider>
				<span data-testid="outside">elsewhere</span>
			</AttachmentUploadProvider>,
		);
		const ev = fileDragEvent("dragover", false);
		act(() => {
			screen.getByTestId("outside").dispatchEvent(ev);
		});
		expect(ev.defaultPrevented).toBe(false);
	});

	it("uploadFiles uploads straight to the folder with no dialog", async () => {
		mutateAsync.mockResolvedValue({});
		function Drop() {
			const { uploadFiles } = useAttachmentUpload();
			return (
				<button type="button" onClick={() => uploadFiles([new File(["x"], "a.png")], "docs")}>
					drop
				</button>
			);
		}
		render(
			<AttachmentUploadProvider>
				<Drop />
			</AttachmentUploadProvider>,
		);
		fireEvent.click(screen.getByText("drop"));
		await waitFor(() =>
			expect(mutateAsync).toHaveBeenCalledWith(expect.objectContaining({ path: "docs/a 1.png" })),
		);
		expect(screen.queryByTestId("dialog")).toBeNull();
	});
});

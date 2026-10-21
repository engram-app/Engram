import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { captureServerFeatures, resetServerFeatures } from "@/api/server-features";
import { AttachmentUploadProvider, useAttachmentUpload } from "./provider";

const mutateAsync = vi.fn();
let mockLimits: Record<string, number | null> = {
	max_file_bytes: null,
	attachment_bytes_cap: null,
};
// undefined = the attachments list has not loaded yet.
let mockAttachments: { path: string; size_bytes: number }[] | undefined;
let mockAttachmentsError = false;
vi.mock("@/api/queries", () => ({
	useFolders: () => ({ data: [{ name: "docs" }] }),
	useAttachments: () => ({ data: mockAttachments, isError: mockAttachmentsError }),
	useUploadAttachment: () => ({ mutateAsync }),
	useCapabilities: () => ({ data: { tier: "free", limits: mockLimits, plan_limits: {} } }),
}));
vi.mock("@/config-context", () => ({ useConfig: () => ({ billingEnabled: true }) }));
vi.mock("./upload-limit-dialog", () => ({
	UploadLimitDialog: ({ tooLarge, noRoom }: { tooLarge: File[]; noRoom: File[] }) => (
		<div data-testid="limit-dialog">{[...tooLarge, ...noRoom].map((f) => f.name).join(",")}</div>
	),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));
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
	resetServerFeatures();
	mockLimits = { max_file_bytes: null, attachment_bytes_cap: null };
	mockAttachments = [{ path: "docs/a.png", size_bytes: 3 }];
	mockAttachmentsError = false;
});

describe("AttachmentUploadProvider plan limits", () => {
	function pick(container: HTMLElement, files: File[]) {
		const input = container.querySelector('input[type="file"]') as HTMLInputElement;
		fireEvent.change(input, { target: { files } });
	}
	const sized = (name: string, size: number) => new File([new Uint8Array(size)], name);

	it("refuses an oversize file at pick time and says so, before the upload dialog", () => {
		mockLimits = { max_file_bytes: 10, attachment_bytes_cap: null };
		const { container } = render(<AttachmentUploadProvider>{null}</AttachmentUploadProvider>);
		pick(container, [sized("big.zip", 11)]);
		expect(screen.getByTestId("limit-dialog")).toHaveTextContent("big.zip");
		expect(screen.queryByTestId("dialog")).toBeNull();
	});

	it("still opens the upload dialog with the files that fit", () => {
		mockLimits = { max_file_bytes: 10, attachment_bytes_cap: null };
		const { container } = render(<AttachmentUploadProvider>{null}</AttachmentUploadProvider>);
		pick(container, [sized("big.zip", 11), sized("ok.txt", 2)]);
		expect(screen.getByTestId("limit-dialog")).toHaveTextContent(/^big\.zip$/u);
		expect(screen.getByTestId("dialog")).toHaveTextContent(/^ok\.txt$/u);
	});

	it("counts what is already stored against the storage cap", () => {
		mockLimits = { max_file_bytes: null, attachment_bytes_cap: 10 };
		const { container } = render(<AttachmentUploadProvider>{null}</AttachmentUploadProvider>);
		// 3 bytes already stored (docs/a.png): 8 more does not fit.
		pick(container, [sized("fits.txt", 7), sized("full.txt", 1)]);
		expect(screen.getByTestId("limit-dialog")).toHaveTextContent(/^full\.txt$/u);
	});
});

describe("AttachmentUploadProvider executables", () => {
	function pick(container: HTMLElement, files: File[]) {
		const input = container.querySelector('input[type="file"]') as HTMLInputElement;
		fireEvent.change(input, { target: { files } });
	}

	it("refuses an executable from the picker before the dialog opens", () => {
		captureServerFeatures({ features: { blocked_extensions: [".appimage"] } });
		const { container } = render(<AttachmentUploadProvider>{null}</AttachmentUploadProvider>);
		pick(container, [new File(["x"], "Tool.AppImage")]);
		expect(screen.queryByTestId("dialog")).toBeNull();
	});

	it("opens the dialog with only the files that can sync", async () => {
		captureServerFeatures({ features: { blocked_extensions: [".appimage"] } });
		const { container } = render(<AttachmentUploadProvider>{null}</AttachmentUploadProvider>);
		pick(container, [new File(["x"], "Tool.AppImage"), new File(["x"], "ok.pdf")]);
		await waitFor(() => expect(screen.getByTestId("dialog")).toHaveTextContent(/^ok\.pdf$/u));
	});
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

	describe("before the attachments list has loaded", () => {
		function Drop() {
			const { uploadFiles, openUpload } = useAttachmentUpload();
			return (
				<>
					<button type="button" onClick={() => uploadFiles([new File(["x"], "a.png")], "docs")}>
						drop
					</button>
					<button type="button" onClick={() => openUpload([new File(["x"], "a.png")], "docs")}>
						open
					</button>
				</>
			);
		}
		const tree = () => (
			<AttachmentUploadProvider>
				<Drop />
			</AttachmentUploadProvider>
		);

		// An empty list would claim the bare name, and the server's upsert by path
		// would silently replace the file already stored there.
		it("a drop waits for the list, then claims a free name", async () => {
			mockAttachments = undefined;
			mutateAsync.mockResolvedValue({});
			const { rerender } = render(tree());
			fireEvent.click(screen.getByText("drop"));
			await act(async () => {
				await Promise.resolve();
			});
			expect(mutateAsync).not.toHaveBeenCalled();
			mockAttachments = [{ path: "docs/a.png", size_bytes: 3 }];
			rerender(tree());
			// A suffixed name, never the bare "docs/a.png" (the number depends on
			// what earlier tests reserved in this module).
			await waitFor(() =>
				expect(mutateAsync).toHaveBeenCalledWith(
					expect.objectContaining({ path: expect.stringMatching(/^docs\/a \d+\.png$/u) }),
				),
			);
		});

		it("the upload dialog opens only once the list has loaded", async () => {
			mockAttachments = undefined;
			const { rerender } = render(tree());
			fireEvent.click(screen.getByText("open"));
			await act(async () => {
				await Promise.resolve();
			});
			expect(screen.queryByTestId("dialog")).toBeNull();
			mockAttachments = [{ path: "docs/a.png", size_bytes: 3 }];
			rerender(tree());
			expect(await screen.findByTestId("dialog")).toHaveTextContent("a.png");
		});

		it("a list that fails to load uploads nothing and says so", async () => {
			mockAttachments = undefined;
			const { rerender } = render(tree());
			fireEvent.click(screen.getByText("drop"));
			mockAttachmentsError = true;
			rerender(tree());
			const { toast } = await import("sonner");
			await waitFor(() => expect(toast.error).toHaveBeenCalled());
			expect(mutateAsync).not.toHaveBeenCalled();
		});
	});
});

import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AttachmentUploadProvider, useAttachmentUpload } from "./provider";

vi.mock("@/api/queries", () => ({
	useFolders: () => ({ data: [{ name: "docs" }] }),
}));
// Render a sentinel instead of the real dialog so this test stays unit-scoped.
vi.mock("./upload-dialog", () => ({
	AttachmentUploadDialog: ({ initialFiles }: { initialFiles: File[] }) => (
		<div data-testid="dialog">{initialFiles.map((f) => f.name).join(",")}</div>
	),
}));
// Controllable demo flag — null (not demo) by default; flip per test.
let demoActive = false;
vi.mock("../../onboarding/tour/demo-vault-provider", () => ({
	useDemoVaultOptional: () => (demoActive ? { active: true } : null),
}));

function TriggerButton() {
	const { openUpload } = useAttachmentUpload();
	return <button onClick={() => openUpload([new File(["x"], "fromButton.txt")])}>open</button>;
}

function fileDragEvent(type: string, withFiles: boolean) {
	const ev = new Event(type, { bubbles: true }) as unknown as DragEvent;
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
	demoActive = false;
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

	it("shows the drop overlay only for a Files drag, not an internal drag", () => {
		render(
			<AttachmentUploadProvider>
				<span>child</span>
			</AttachmentUploadProvider>,
		);
		// internal (no Files) drag — overlay stays hidden. act() flushes the
		// window-listener's state update (React 19 batches it, so a bare dispatch +
		// sync assert races the render).
		act(() => {
			window.dispatchEvent(fileDragEvent("dragenter", false));
		});
		expect(screen.queryByText(/drop files to upload/iu)).toBeNull();
		// external Files drag — overlay shows
		act(() => {
			window.dispatchEvent(fileDragEvent("dragenter", true));
		});
		expect(screen.getByText(/drop files to upload/iu)).toBeInTheDocument();
	});

	it("opens the dialog with dropped files", async () => {
		render(
			<AttachmentUploadProvider>
				<span>child</span>
			</AttachmentUploadProvider>,
		);
		window.dispatchEvent(fileDragEvent("drop", true));
		await waitFor(() => expect(screen.getByTestId("dialog")).toHaveTextContent("dropped.txt"));
	});

	it("is inert for demo vaults: no overlay, no dialog on drop or openUpload", () => {
		demoActive = true;
		render(
			<AttachmentUploadProvider>
				<TriggerButton />
			</AttachmentUploadProvider>,
		);
		// Button is a no-op: clicking opens nothing.
		fireEvent.click(screen.getByText("open"));
		expect(screen.queryByTestId("dialog")).toBeNull();
		// External file drop is ignored: no overlay, no dialog.
		act(() => {
			window.dispatchEvent(fileDragEvent("dragenter", true));
		});
		expect(screen.queryByText(/drop files to upload/iu)).toBeNull();
		act(() => {
			window.dispatchEvent(fileDragEvent("drop", true));
		});
		expect(screen.queryByTestId("dialog")).toBeNull();
	});
});

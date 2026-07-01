import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import FilesPanel from "./files-panel";

// FilesPanel → FolderActions reads useAttachmentUpload; stub the provider so the
// panel renders without an AttachmentUploadProvider wrapper.
vi.mock("../viewer/attachment-upload/provider", () => ({
	useAttachmentUpload: () => ({ openUpload: vi.fn() }),
}));

function renderPanel() {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter>
				<FilesPanel />
			</MemoryRouter>
		</QueryClientProvider>,
	);
}

describe("FilesPanel", () => {
	it('renders the panel header "Files"', () => {
		renderPanel();
		expect(screen.getByRole("heading", { name: "Files", level: 2 })).toBeInTheDocument();
	});

	it("mounts the folder tree region", () => {
		renderPanel();
		expect(screen.getByTestId("folder-tree-root")).toBeInTheDocument();
	});
});

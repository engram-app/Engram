import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { MemoryRouter } from "react-router";
import { describe, expect, it, vi } from "vitest";
import FilesPanel from "./files-panel";
import { RailViewProvider } from "./rail-view-context";

// FilesPanel → FolderActions reads useAttachmentUpload; stub the provider so the
// panel renders without an AttachmentUploadProvider wrapper.
vi.mock("../viewer/attachment-upload/provider", () => ({
	useAttachmentUpload: () => ({ openUpload: vi.fn() }),
	useFileDropUpload: () => null,
}));

function renderPanel() {
	const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
	return render(
		<QueryClientProvider client={qc}>
			<MemoryRouter>
				{/* The header's collapse button talks to the rail's sidebar state. */}
				<RailViewProvider>
					<FilesPanel />
				</RailViewProvider>
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

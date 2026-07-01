import { describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";

import { AttachmentFallback } from "./attachment-fallback";

const showUpgradeMock = vi.fn();

vi.mock("@/billing/upgrade-dialog-provider", () => ({
	useUpgradeDialog: () => ({ showUpgrade: showUpgradeMock }),
}));

describe("AttachmentFallback", () => {
	it("renders lock + filename", () => {
		render(<AttachmentFallback filename="image.png" />);
		expect(screen.getByText("image.png")).toBeInTheDocument();
		expect(screen.getByTestId("attachment-fallback-lock")).toBeInTheDocument();
	});

	it("clicking opens upgrade dialog with attachments_disabled", () => {
		showUpgradeMock.mockClear();
		render(<AttachmentFallback filename="x.pdf" />);
		fireEvent.click(screen.getByTestId("attachment-fallback-lock"));
		expect(showUpgradeMock).toHaveBeenCalledWith("attachments_disabled");
	});
});

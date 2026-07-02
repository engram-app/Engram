import { render, screen, waitFor } from "@testing-library/react";
import { useEffect } from "react";
import { expect, it, vi } from "vitest";
import PdfView from "./pdf-view";

// pdf.js can't render in jsdom (canvas + worker), so stub react-pdf: Document
// reports a fixed page count, Page renders a marker. This verifies PdfView's
// own logic — the page loop driven by onLoadSuccess.
vi.mock("react-pdf", () => ({
	pdfjs: { GlobalWorkerOptions: {} },
	Document: ({
		onLoadSuccess,
		children,
	}: {
		onLoadSuccess?: (d: { numPages: number }) => void;
		children: React.ReactNode;
	}) => {
		useEffect(() => onLoadSuccess?.({ numPages: 3 }), [onLoadSuccess]);
		return <div data-testid="pdf-document">{children}</div>;
	},
	Page: ({ pageNumber }: { pageNumber: number }) => (
		<div data-testid="pdf-page">page {pageNumber}</div>
	),
}));

it("renders one Page per page reported by the document", async () => {
	render(<PdfView url="blob:fake" filename="doc.pdf" />);
	await waitFor(() => expect(screen.getAllByTestId("pdf-page")).toHaveLength(3));
	expect(screen.getByText("page 1")).toBeInTheDocument();
	expect(screen.getByText("page 3")).toBeInTheDocument();
});

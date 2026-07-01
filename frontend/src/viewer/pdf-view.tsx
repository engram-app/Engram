import { useEffect, useRef, useState } from "react";
import { Document, Page, pdfjs } from "react-pdf";
import "react-pdf/dist/Page/AnnotationLayer.css";
import "react-pdf/dist/Page/TextLayer.css";
import LoadingPane from "./loading-pane";
import PreviewColumn from "./preview-column";

// Self-host the pdf.js worker from the bundled pdfjs-dist (Vite resolves the
// `new URL(..., import.meta.url)` asset reference at build time). Keeps PDF
// rendering offline / same-origin — no CDN fetch.
pdfjs.GlobalWorkerOptions.workerSrc = new URL(
	"pdfjs-dist/build/pdf.worker.min.mjs",
	import.meta.url,
).toString();

// Cap page render width to roughly a natural Letter/A4 page (~800px) so pages
// read as a centered document column instead of stretching across wide panes.
const MAX_PAGE_WIDTH = 800;

// Continuous, fit-to-width PDF viewer. Mirrors the note view's surface — a
// centered max-w-[840px] card column with a ScrollArea — and stacks every page
// in one scroll column over a muted gutter so the white pages stay distinct.
export default function PdfView({ url, filename }: { url: string; filename: string }) {
	const containerRef = useRef<HTMLDivElement>(null);
	const [numPages, setNumPages] = useState(0);
	const [width, setWidth] = useState(0);

	useEffect(() => {
		const measure = () => setWidth(containerRef.current?.clientWidth ?? 0);
		measure();
		window.addEventListener("resize", measure);
		return () => window.removeEventListener("resize", measure);
	}, []);

	// p-4 gutter (16 each side) — render slightly narrower than the column, capped
	// so pages never blow past a natural page width.
	const pageWidth = width ? Math.min(width - 32, MAX_PAGE_WIDTH) : undefined;

	return (
		<PreviewColumn>
			<div ref={containerRef} className="w-full p-4">
				<Document
					file={url}
					onLoadSuccess={({ numPages }) => setNumPages(numPages)}
					className="flex flex-col items-center gap-4"
					loading={<LoadingPane />}
					error={<p className="p-2 text-sm text-destructive">Couldn&apos;t render {filename}.</p>}
				>
					{Array.from({ length: numPages }, (_, i) => (
						<Page
							key={i + 1}
							pageNumber={i + 1}
							width={pageWidth}
							className="shadow-md"
							renderAnnotationLayer={false}
						/>
					))}
				</Document>
			</div>
		</PreviewColumn>
	);
}

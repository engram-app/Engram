import { useEffect, useRef, useState } from 'react'
import { Document, Page, pdfjs } from 'react-pdf'
import 'react-pdf/dist/Page/AnnotationLayer.css'
import 'react-pdf/dist/Page/TextLayer.css'

// Self-host the pdf.js worker from the bundled pdfjs-dist (Vite resolves the
// `new URL(..., import.meta.url)` asset reference at build time). Keeps PDF
// rendering offline / same-origin — no CDN fetch.
pdfjs.GlobalWorkerOptions.workerSrc = new URL(
  'pdfjs-dist/build/pdf.worker.min.mjs',
  import.meta.url,
).toString()

// Continuous, fit-to-width PDF viewer. Renders every page stacked in one
// scroll column (our chrome, not the browser's iframe toolbar). The page
// width tracks the container so pages fill the pane and reflow on resize.
export default function PdfView({ url, filename }: { url: string; filename: string }) {
  const containerRef = useRef<HTMLElement>(null)
  const [numPages, setNumPages] = useState(0)
  const [width, setWidth] = useState(0)

  useEffect(() => {
    const measure = () => setWidth(containerRef.current?.clientWidth ?? 0)
    measure()
    window.addEventListener('resize', measure)
    return () => window.removeEventListener('resize', measure)
  }, [])

  // px-4 padding (16 each side) — render slightly narrower than the container,
  // capped so pages don't blow up on ultra-wide panes.
  const pageWidth = width ? Math.min(width - 32, 1000) : undefined

  return (
    <section ref={containerRef} className="h-full overflow-auto bg-muted/30 px-4 py-4">
      <Document
        file={url}
        onLoadSuccess={({ numPages }) => setNumPages(numPages)}
        loading={<p className="text-sm text-muted-foreground">Loading {filename}…</p>}
        error={<p className="text-sm text-destructive">Couldn&apos;t render {filename}.</p>}
      >
        {Array.from({ length: numPages }, (_, i) => (
          <Page
            key={i + 1}
            pageNumber={i + 1}
            width={pageWidth}
            className="mx-auto mb-4 shadow-sm"
            renderAnnotationLayer={false}
          />
        ))}
      </Document>
    </section>
  )
}

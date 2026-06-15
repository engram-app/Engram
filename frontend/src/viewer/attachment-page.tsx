import { lazy, Suspense, useEffect, useState } from 'react'
import { useParams } from 'react-router'
import { api } from '../api/client'

// pdf.js is heavy — only pull its chunk when a PDF is actually opened, never
// for image/other previews.
const PdfView = lazy(() => import('./pdf-view'))

// Read-only preview for a single attachment. The path is the route splat
// (`/attachment/*`). Fetches raw bytes (?raw=1) as a typed Blob so the browser
// renders images / PDFs natively; unsupported types fall back to a download link.
export default function AttachmentPage() {
  const params = useParams()
  const path = params['*'] ?? ''
  const filename = path.split('/').pop() ?? path

  const [url, setUrl] = useState<string | null>(null)
  const [mime, setMime] = useState<string>('')
  const [error, setError] = useState(false)

  useEffect(() => {
    let revoke: string | null = null
    let cancelled = false
    setUrl(null)
    setError(false)
    const encoded = path.split('/').map(encodeURIComponent).join('/')
    api
      .getBlob(`/attachments/${encoded}?raw=1`)
      .then((blob) => {
        if (cancelled) return
        const objectUrl = URL.createObjectURL(blob)
        revoke = objectUrl
        setMime(blob.type)
        setUrl(objectUrl)
      })
      .catch(() => !cancelled && setError(true))
    return () => {
      cancelled = true
      if (revoke) URL.revokeObjectURL(revoke)
    }
  }, [path])

  if (error) {
    return (
      <section className="p-6">
        <p className="text-sm text-destructive">Couldn&apos;t load {filename}.</p>
      </section>
    )
  }
  if (!url) {
    return (
      <section className="p-6">
        <p className="text-sm text-muted-foreground">Loading {filename}…</p>
      </section>
    )
  }
  if (mime.startsWith('image/')) {
    return (
      <section className="flex h-full items-center justify-center overflow-auto p-6">
        <img src={url} alt={filename} className="max-h-full max-w-full rounded" />
      </section>
    )
  }
  if (mime === 'application/pdf') {
    return (
      <Suspense
        fallback={
          <section className="p-6">
            <p className="text-sm text-muted-foreground">Loading viewer…</p>
          </section>
        }
      >
        <PdfView url={url} filename={filename} />
      </Suspense>
    )
  }
  return (
    <section className="p-6">
      <p className="mb-3 text-sm text-muted-foreground">Preview not supported for {filename}.</p>
      <a
        href={url}
        download={filename}
        className="inline-flex items-center rounded bg-primary px-3 py-2 text-sm text-primary-foreground"
      >
        Download {filename}
      </a>
    </section>
  )
}

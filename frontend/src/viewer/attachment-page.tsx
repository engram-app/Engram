import { lazy, Suspense, useEffect, useState } from 'react'
import { useParams } from 'react-router'
import { api, ApiError } from '../api/client'
import { useAttachments } from '../api/queries'
import LoadingPane from './loading-pane'
import PreviewColumn from './preview-column'

// pdf.js is heavy — only pull its chunk when a PDF is actually opened, never
// for image/other previews.
const PdfView = lazy(() => import('./pdf-view'))

// Read-only preview for a single attachment, routed by uuid (/attachment/:id) —
// like notes, so the URL survives a rename/move. Resolves the id to its path +
// mime from the already-loaded attachments list (the tree sidebar keeps it
// warm), then streams raw bytes (?raw=1) as a typed Blob so the browser renders
// images / PDFs natively; unsupported types fall back to a download link.
export default function AttachmentPage() {
  const { id } = useParams()
  const { data: attachments, isLoading } = useAttachments()
  const att = attachments?.find((a) => a.id === id)
  const path = att?.path ?? ''
  const filename = path.split('/').pop() ?? path
  const mime = att?.mime_type ?? ''

  const [url, setUrl] = useState<string | null>(null)
  // 'missing' = real 404; 'failed' = transient (5xx/network) — don't conflate.
  const [error, setError] = useState<'missing' | 'failed' | null>(null)

  useEffect(() => {
    if (!path) return
    let revoke: string | null = null
    let cancelled = false
    setUrl(null)
    setError(null)
    const encoded = path.split('/').map(encodeURIComponent).join('/')
    api
      .getBlob(`/attachments/${encoded}?raw=1`)
      .then((blob) => {
        if (cancelled) return
        const objectUrl = URL.createObjectURL(blob)
        revoke = objectUrl
        setUrl(objectUrl)
      })
      .catch((err) => {
        if (cancelled) return
        if (!(err instanceof ApiError)) console.error('attachment load failed', path, err)
        setError(err instanceof ApiError && err.status === 404 ? 'missing' : 'failed')
      })
    return () => {
      cancelled = true
      if (revoke) URL.revokeObjectURL(revoke)
    }
  }, [path])

  // Attachment list still loading and the id isn't resolved yet.
  if (!att && isLoading) {
    return <LoadingPane />
  }
  // List loaded but no attachment with this id (deleted, or a stale link).
  if (!att) {
    return (
      <section className="p-6">
        <p className="text-sm text-destructive">Attachment not found.</p>
      </section>
    )
  }
  if (error) {
    return (
      <section className="p-6">
        <p className="text-sm text-destructive">
          {error === 'missing'
            ? `${filename} no longer exists.`
            : `Couldn't load ${filename} — it may be temporarily unavailable.`}
        </p>
      </section>
    )
  }
  if (!url) {
    return <LoadingPane />
  }
  if (mime.startsWith('image/')) {
    return (
      <PreviewColumn>
        <div className="flex w-full justify-center p-4">
          <img
            src={url}
            alt={filename}
            className="max-w-full rounded shadow-md"
            style={{ maxWidth: 800 }}
          />
        </div>
      </PreviewColumn>
    )
  }
  if (mime === 'application/pdf') {
    return (
      <Suspense fallback={<LoadingPane />}>
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

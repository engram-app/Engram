import { useEffect, useState } from 'react'
import { api } from '../api/client'

export default function AttachmentImg({ path, alt }: { path: string; alt?: string }) {
  const [src, setSrc] = useState<string | null>(null)
  const [error, setError] = useState(false)

  useEffect(() => {
    let revoke: string | null = null
    let cancelled = false
    const encoded = path.split('/').map(encodeURIComponent).join('/')
    api
      .getBlob(`/attachments/${encoded}?raw=1`)
      .then((blob) => {
        if (cancelled) return
        const url = URL.createObjectURL(blob)
        revoke = url
        setSrc(url)
      })
      .catch(() => !cancelled && setError(true))
    return () => {
      cancelled = true
      if (revoke) URL.revokeObjectURL(revoke)
    }
  }, [path])

  if (error) {
    return (
      <span className="inline-flex items-center gap-1 rounded bg-destructive/10 px-1.5 py-0.5 text-xs text-destructive">
        Missing attachment: {path}
      </span>
    )
  }
  if (!src) {
    return <span className="text-xs text-muted-foreground">Loading {path}…</span>
  }
  return <img src={src} alt={alt ?? path} className="my-2 max-w-full rounded" />
}

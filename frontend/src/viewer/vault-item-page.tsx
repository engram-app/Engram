import { lazy, Suspense } from 'react'
import { useParams } from 'react-router'
import { useAttachments } from '../api/queries'

// Both viewers are heavy (NotePage pulls remark/CodeMirror; AttachmentPage pulls
// pdf.js on demand) — load whichever the route resolves to.
const NotePage = lazy(() => import('./note-page'))
const AttachmentPage = lazy(() => import('./attachment-page'))

// Resolver behind the unified /note/:id route. Notes and attachments share one
// URL shape (like Obsidian, where everything is a vault item) — decide which
// viewer to mount by checking the loaded attachments list. The tree sidebar
// keeps that list warm, so in-app navigation resolves instantly; a cold
// deep-link to an attachment briefly renders NotePage until the list lands,
// then re-resolves (the common case — a note — is never delayed).
export default function VaultItemPage() {
  const { id } = useParams()
  const { data: attachments } = useAttachments()
  const isAttachment = attachments?.some((a) => a.id === id) ?? false

  return (
    <Suspense fallback={<p className="p-6 text-sm text-muted-foreground">Loading…</p>}>
      {isAttachment ? <AttachmentPage /> : <NotePage />}
    </Suspense>
  )
}

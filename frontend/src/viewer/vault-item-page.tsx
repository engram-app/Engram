import { lazy, Suspense } from "react";
import { useParams } from "react-router";
import { useAttachments } from "../api/queries";
import LoadingPane from "./loading-pane";

// Both viewers are heavy (NotePage pulls remark/CodeMirror; AttachmentPage pulls
// pdf.js on demand) — load whichever the route resolves to.
const NotePage = lazy(() => import("./note-page"));
const AttachmentPage = lazy(() => import("./attachment-page"));

// Resolver behind the unified /note/:id route. Notes and attachments share one
// URL shape (like Obsidian, where everything is a vault item) — decide which
// viewer to mount by checking the loaded attachments list. The tree sidebar
// keeps that list warm, so in-app navigation resolves instantly; a cold
// deep-link to an attachment briefly renders NotePage until the list lands,
// then re-resolves (the common case — a note — is never delayed).
export default function VaultItemPage() {
	const { id } = useParams();
	const { data: attachments, isLoading } = useAttachments();

	// Until the attachments list has loaded we can't tell a note id from an
	// attachment id, so wait — don't guess "note" and mount NotePage, which would
	// fire a doomed GET /notes/:id for an attachment id and flash a 404 error on a
	// valid attachment deep-link. The list is warm from the sidebar on in-app nav,
	// so this only briefly gates a cold deep-link / hard refresh. (If the list
	// outright failed, `attachments` is undefined → we fall through to NotePage,
	// the common case — an accepted degradation since a failed list already breaks
	// the sidebar.)
	if (isLoading && !attachments) {
		return <LoadingPane />;
	}
	const isAttachment = attachments?.some((a) => a.id === id) ?? false;

	return (
		<Suspense fallback={<LoadingPane />}>
			{isAttachment ? <AttachmentPage /> : <NotePage />}
		</Suspense>
	);
}

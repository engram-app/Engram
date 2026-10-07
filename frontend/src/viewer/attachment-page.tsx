import { Download } from "lucide-react";
import { lazy, type ReactNode, Suspense, useEffect, useState } from "react";
import { useParams } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { encodePathSegments } from "@/lib/path";
import { ApiError, api, isNotFound } from "../api/client";
import { useAttachments } from "../api/queries";
import { DocumentHeader } from "./document-header";
import { DocumentSurface } from "./document-surface";
import LoadingPane from "./loading-pane";
import PreviewColumn from "./preview-column";

// pdf.js is heavy — only pull its chunk when a PDF is actually opened, never
// for image/other previews.
const PdfView = lazy(() => import("./pdf-view"));

// Read-only preview for a single attachment, routed by uuid (/attachment/:id) —
// like notes, so the URL survives a rename/move. Resolves the id to its path +
// mime from the already-loaded attachments list (the tree sidebar keeps it
// warm), then streams raw bytes (?raw=1) as a typed Blob so the browser renders
// images / PDFs natively; unsupported types fall back to a download link.
export default function AttachmentPage() {
	const { t } = useT();
	const { itemId: id } = useParams();
	const { data: attachments, isLoading } = useAttachments();
	const att = attachments?.find((a) => a.id === id);
	const path = att?.path ?? "";
	const filename = path.split("/").pop() ?? path;
	const mime = att?.mime_type ?? "";

	const [url, setUrl] = useState<string | null>(null);
	// 'missing' = real 404; 'failed' = transient (5xx/network) — don't conflate.
	const [error, setError] = useState<"missing" | "failed" | null>(null);

	// A new `path` is a new resource: drop the previous blob url and error
	// during render rather than one paint later from inside the effect.
	const [seededPath, setSeededPath] = useState(path);
	if (seededPath !== path) {
		setSeededPath(path);
		setUrl(null);
		setError(null);
	}

	useEffect(() => {
		if (!path) {
			return;
		}
		let revoke: string | null = null;
		let cancelled = false;
		api
			.getBlob(`/attachments/${encodePathSegments(path)}?raw=1`)
			.then((blob) => {
				if (cancelled) {
					return;
				}
				const objectUrl = URL.createObjectURL(blob);
				revoke = objectUrl;
				setUrl(objectUrl);
			})
			.catch((err) => {
				if (cancelled) {
					return;
				}
				if (!(err instanceof ApiError)) {
					// Path withheld: an attachment path is folder structure plus a filename
					// ("Medical/2026-lab-results.pdf"), and console args become Sentry
					// breadcrumbs as well as sitting in a console the user may screenshot.
					console.error("attachment load failed", err);
				}
				setError(isNotFound(err) ? "missing" : "failed");
			});
		return () => {
			cancelled = true;
			if (revoke) {
				URL.revokeObjectURL(revoke);
			}
		};
	}, [path]);

	// Attachment list still loading and the id isn't resolved yet.
	if (!att && isLoading) {
		return <LoadingPane />;
	}
	// List loaded but no attachment with this id (deleted, or a stale link).
	if (!att) {
		return (
			<DocumentSurface>
				<p className="p-6 text-destructive text-sm">{t("Attachment not found.")}</p>
			</DocumentSurface>
		);
	}

	let body: ReactNode;
	if (error) {
		body = (
			<p className="p-6 text-destructive text-sm">
				{error === "missing"
					? t("{filename} no longer exists.", { filename })
					: t("Couldn't load {filename} — it may be temporarily unavailable.", { filename })}
			</p>
		);
	} else if (!url) {
		body = <LoadingPane />;
	} else if (mime.startsWith("image/")) {
		body = (
			<PreviewColumn>
				<div className="flex w-full justify-center p-4">
					<img
						draggable={false}
						src={url}
						alt={filename}
						className="max-w-full rounded shadow-md"
						style={{ maxWidth: 800 }}
					/>
				</div>
			</PreviewColumn>
		);
	} else if (mime === "application/pdf") {
		body = (
			<Suspense fallback={<LoadingPane />}>
				<PdfView url={url} filename={filename} />
			</Suspense>
		);
	} else {
		body = (
			<p className="p-6 text-muted-foreground text-sm">
				{t("Preview not supported for {filename}. Use Download above to save it.", { filename })}
			</p>
		);
	}

	// Same surface and header as a note, so an attachment reads as a page in the
	// vault rather than replacing the document view.
	return (
		<DocumentSurface>
			<DocumentHeader
				folder={path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : undefined}
				title={path}
				name={<span className="min-w-0 truncate font-medium">{filename}</span>}
				// Always rendered, disabled until the bytes land: an icon button is taller
				// than the bare text row, so mounting it late made the header jump.
				actions={
					url ? (
						<Button variant="ghost" size="icon" asChild>
							<a
								href={url}
								download={filename}
								aria-label={t("Download {filename}", { filename })}
								title={t("Download")}
							>
								<Download className="size-4" />
							</a>
						</Button>
					) : (
						<Button
							variant="ghost"
							size="icon"
							disabled
							aria-label={t("Download")}
							title={t("Download")}
						>
							<Download className="size-4" />
						</Button>
					)
				}
			/>
			{body}
		</DocumentSurface>
	);
}

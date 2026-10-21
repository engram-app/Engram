import { Download } from "lucide-react";
import { lazy, type ReactNode, Suspense, useEffect, useMemo, useState } from "react";
import { useParams } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { notify } from "@/lib/notify";
import { encodePathSegments } from "@/lib/path";
import { whenLoaded } from "@/lib/when-loaded";
import { ApiError, api, isNotFound } from "../api/client";
import { useAttachments } from "../api/queries";
import { useRightToolSlot } from "../layout/right-tools-context";
import { AttachmentDetails, AttachmentName } from "./attachment-details";
import { opensInline, previewKind } from "./attachment-preview";
import { AttachmentTextPreview } from "./attachment-text-preview";
import BacklinksPanel from "./backlinks-panel";
import { DocumentHeader } from "./document-header";
import { DocumentSurface } from "./document-surface";
import LoadingPane from "./loading-pane";
import PreviewColumn from "./preview-column";

// pdf.js is heavy — only pull its chunk when a PDF is actually opened, never
// for image/other previews.
const PdfView = lazy(() => whenLoaded(import("./pdf-view")));

// Read-only preview for a single attachment, routed by uuid (/attachment/:id) —
// like notes, so the URL survives a rename/move. Resolves the id to its path +
// mime from the already-loaded attachments list (the tree sidebar keeps it
// warm). Previewable files (see previewKind) stream their raw bytes (?raw=1) as
// a typed Blob for a native or text preview; everything else gets the file card
// alone and fetches its bytes only when the user downloads.
export default function AttachmentPage() {
	const { t } = useT();
	const { itemId: id } = useParams();
	const { data: attachments, isLoading } = useAttachments();
	const att = attachments?.find((a) => a.id === id);
	const path = att?.path ?? "";
	const filename = path.split("/").pop() ?? path;
	const mime = att?.mime_type ?? "";
	const kind = att ? previewKind(path, mime, att.size_bytes) : null;
	const rawPath = `/attachments/${encodePathSegments(path)}?raw=1`;

	// Which name is in rename mode: the pinned header, or the title on the page.
	const [renamingAt, setRenamingAt] = useState<"header" | "title" | null>(null);
	const [blob, setBlob] = useState<Blob | null>(null);
	const [url, setUrl] = useState<string | null>(null);
	// 'missing' = real 404; 'failed' = transient (5xx/network) — don't conflate.
	const [error, setError] = useState<"missing" | "failed" | null>(null);

	// A new `path` is a new resource: drop the previous blob url and error
	// during render rather than one paint later from inside the effect.
	const [seededPath, setSeededPath] = useState(path);
	if (seededPath !== path) {
		setSeededPath(path);
		setBlob(null);
		setUrl(null);
		setError(null);
	}

	useEffect(() => {
		if (!path || kind === null) {
			return;
		}
		let revoke: string | null = null;
		let cancelled = false;
		api
			.getBlob(rawPath)
			.then((fetched) => {
				if (cancelled) {
					return;
				}
				const objectUrl = URL.createObjectURL(fetched);
				revoke = objectUrl;
				setBlob(fetched);
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
	}, [path, kind, rawPath]);

	// Same right-rail Backlinks panel a note gets.
	const backlinksNode = useMemo(() => (id ? <BacklinksPanel attachmentId={id} /> : null), [id]);
	useRightToolSlot("backlinks", backlinksNode);

	// Previewed files already hold their bytes; the rest fetch them on click.
	async function download() {
		let href = url;
		if (!href) {
			try {
				href = URL.createObjectURL(await api.getBlob(rawPath));
			} catch (err) {
				if (!(err instanceof ApiError)) {
					console.error("attachment download failed", err);
				}
				notify.error(t("Couldn't download {filename}. Try again.", { filename }));
				return;
			}
		}
		const a = document.createElement("a");
		a.href = href;
		a.download = filename;
		a.click();
		if (href !== url) {
			// After the click has handed the blob to the download manager.
			setTimeout(() => URL.revokeObjectURL(href), 0);
		}
	}

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

	let preview: ReactNode = null;
	if (error) {
		preview = (
			<p className="text-destructive text-sm">
				{error === "missing"
					? t("{filename} no longer exists.", { filename })
					: t("Couldn't load {filename} — it may be temporarily unavailable.", { filename })}
			</p>
		);
	} else if (kind !== null && !(url && blob)) {
		preview = <LoadingPane />;
	} else if (url && blob) {
		if (kind === "image") {
			preview = (
				<img
					draggable={false}
					src={url}
					alt={filename}
					className="mx-auto max-w-full rounded shadow-md"
					style={{ maxWidth: 800 }}
				/>
			);
		} else if (kind === "audio") {
			// biome-ignore lint/a11y/useMediaCaption: user files ship no caption track to attach.
			preview = <audio controls src={url} className="w-full" />;
		} else if (kind === "video") {
			// biome-ignore lint/a11y/useMediaCaption: user files ship no caption track to attach.
			preview = <video controls src={url} className="max-h-[70vh] w-full rounded bg-black" />;
		} else if (kind === "text" || kind === "csv") {
			preview = <AttachmentTextPreview blob={blob} csv={kind === "csv"} filename={filename} />;
		}
	}

	const body =
		kind === "pdf" && !error ? (
			// The PDF viewer owns its scroll and fills the page; no card under it.
			url ? (
				<Suspense fallback={<LoadingPane />}>
					<PdfView url={url} filename={filename} />
				</Suspense>
			) : (
				<LoadingPane />
			)
		) : (
			<PreviewColumn>
				<article className="flex flex-col gap-6 p-6">
					{preview}
					<AttachmentDetails
						att={att}
						kind={kind}
						inlineUrl={url && opensInline(mime) ? url : null}
						onDownload={download}
						renaming={renamingAt === "title"}
						onRename={() => setRenamingAt("title")}
						onRenameDone={() => setRenamingAt(null)}
					/>
				</article>
			</PreviewColumn>
		);

	// Same surface and header as a note, so an attachment reads as a page in the
	// vault rather than replacing the document view.
	return (
		<DocumentSurface>
			<DocumentHeader
				folder={path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : undefined}
				title={path}
				name={
					<AttachmentName
						path={path}
						editing={renamingAt === "header"}
						onEdit={() => setRenamingAt("header")}
						onDone={() => setRenamingAt(null)}
						className="-mx-1 truncate px-1 font-medium"
					/>
				}
				// Always rendered, disabled until the bytes land: an icon button is taller
				// than the bare text row, so mounting it late made the header jump.
				actions={
					<Button
						variant="ghost"
						size="icon"
						onClick={download}
						aria-label={t("Download {filename}", { filename })}
						title={t("Download")}
					>
						<Download className="size-4" />
					</Button>
				}
			/>
			{body}
		</DocumentSurface>
	);
}

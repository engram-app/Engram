import { Download } from "lucide-react";
import { lazy, type ReactNode, Suspense, useEffect, useMemo, useRef, useState } from "react";
import { useParams } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { intlLocale } from "@/lib/intl-locale";
import { notify } from "@/lib/notify";
import { encodePathSegments } from "@/lib/path";
import { whenLoaded } from "@/lib/when-loaded";
import { ApiError, api, isNotFound } from "../api/client";
import { useAttachments } from "../api/queries";
import { useRightToolSlot } from "../layout/right-tools-context";
import { AttachmentDetails, AttachmentName } from "./attachment-details";
import { formatBytes, opensInline, previewKind } from "./attachment-preview";
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
	const { t, renderedLocale } = useT();
	const { itemId: id } = useParams();
	const { data: attachments, isLoading } = useAttachments();
	const att = attachments?.find((a) => a.id === id);
	const path = att?.path ?? "";
	const filename = path.split("/").pop() ?? path;
	const mime = att?.mime_type ?? "";
	const kind = att ? previewKind(path, mime) : null;
	const rawPath = `/attachments/${encodePathSegments(path)}?raw=1`;
	// The bytes are keyed by WHAT the file is, not where it lives: a rename or
	// move changes the path but not the content, so it must not refetch them.
	const contentKey = att ? `${att.id}:${att.size_bytes}:${att.mtime}` : "";
	// Read in the fetch effect so a path change alone does not re-run it.
	const rawPathRef = useRef(rawPath);
	// biome-ignore lint/nursery/useReactCompiler: latest-ref pattern, deliberate. The fetch must use the CURRENT path but re-run only when the content changes.
	rawPathRef.current = rawPath;

	// Which name is in rename mode: the pinned header, or the title on the page.
	const [renamingAt, setRenamingAt] = useState<"header" | "title" | null>(null);
	const [blob, setBlob] = useState<Blob | null>(null);
	const [url, setUrl] = useState<string | null>(null);
	// 'missing' = real 404; 'failed' = transient (5xx/network) — don't conflate.
	const [error, setError] = useState<"missing" | "failed" | null>(null);
	// Bytes of the preview received so far, for the progress bar.
	const [received, setReceived] = useState(0);
	// The browser refused to render the bytes (HEIC in Chrome, MKV, ...).
	const [unrenderable, setUnrenderable] = useState(false);

	// New content is a new resource: drop the previous blob url and error
	// during render rather than one paint later from inside the effect.
	const [seededKey, setSeededKey] = useState(contentKey);
	if (seededKey !== contentKey) {
		setSeededKey(contentKey);
		setUnrenderable(false);
		setReceived(0);
		setBlob(null);
		setUrl(null);
		setError(null);
	}

	useEffect(() => {
		if (!contentKey || kind === null) {
			return;
		}
		let revoke: string | null = null;
		let cancelled = false;
		api
			.getBlob(rawPathRef.current, (n) => {
				if (!cancelled) {
					setReceived(n);
				}
			})
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
	}, [contentKey, kind]);

	// The browser may not decode the format (HEIC in Chrome). Probe it off-DOM
	// so a failure shows a message instead of a broken image.
	useEffect(() => {
		if (kind !== "image" || !url) {
			return;
		}
		let cancelled = false;
		const probe = new Image();
		probe.src = url;
		probe.decode?.().catch(() => {
			if (!cancelled) {
				setUnrenderable(true);
			}
		});
		return () => {
			cancelled = true;
		};
	}, [kind, url]);

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
		const fmt = (n: number) => formatBytes(n, intlLocale(renderedLocale));
		preview = (
			// Centered in the space the preview will fill, so it reads as the
			// preview loading rather than a stray control.
			<div
				role="status"
				className="flex min-h-[40vh] flex-col items-center justify-center gap-2 text-muted-foreground text-sm"
			>
				<progress
					aria-label={t("Loading {filename}", { filename })}
					value={received}
					max={att.size_bytes || undefined}
					className="h-1.5 w-full max-w-md appearance-none overflow-hidden rounded-full bg-foreground/15 [&::-moz-progress-bar]:bg-primary [&::-webkit-progress-bar]:bg-foreground/15 [&::-webkit-progress-value]:rounded-full [&::-webkit-progress-value]:bg-primary"
				/>
				{received === 0
					? t("Loading {filename}…", { filename })
					: t("{received} of {total}", { received: fmt(received), total: fmt(att.size_bytes) })}
			</div>
		);
	} else if (unrenderable) {
		preview = (
			<p className="text-muted-foreground text-sm">
				{t("This browser can't preview {filename}. Download it to open it.", { filename })}
			</p>
		);
	} else if (url && blob) {
		const onRenderError = () => setUnrenderable(true);
		if (kind === "image") {
			preview = (
				<img
					draggable={false}
					src={url}
					alt={filename}
					className="mx-auto block max-w-full rounded shadow-md"
					style={{ maxWidth: 800 }}
				/>
			);
		} else if (kind === "audio") {
			// biome-ignore lint/a11y/useMediaCaption: user files ship no caption track to attach.
			preview = <audio controls src={url} className="w-full" onError={onRenderError} />;
		} else if (kind === "video") {
			preview = (
				// biome-ignore lint/a11y/useMediaCaption: user files ship no caption track to attach.
				<video
					controls
					src={url}
					className="max-h-[70vh] w-full rounded bg-black"
					onError={onRenderError}
				/>
			);
		} else if (kind === "text" || kind === "csv") {
			preview = <AttachmentTextPreview blob={blob} csv={kind === "csv"} filename={filename} />;
		}
	}

	const details = (
		<AttachmentDetails
			att={att}
			kind={kind}
			inlineUrl={url && opensInline(mime) ? url : null}
			onDownload={download}
			renaming={renamingAt === "title"}
			onRename={() => setRenamingAt("title")}
			onRenameDone={() => setRenamingAt(null)}
		/>
	);

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
		) : (kind === "text" || kind === "csv") && !error && !unrenderable ? (
			// Text and tables fill the page and scroll INSIDE their own frame, so a
			// long file never scrolls the details and buttons away.
			<article className="flex min-h-0 flex-1 flex-col gap-6 p-6">
				{details}
				{preview}
			</article>
		) : (
			<PreviewColumn>
				<article className="flex flex-col gap-6 p-6">
					{details}
					{preview}
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

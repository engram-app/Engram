import {
	Download,
	ExternalLink,
	File,
	FileArchive,
	FileAudio,
	FileCode,
	FileImage,
	FileSpreadsheet,
	FileText,
	FileVideo,
	FolderInput,
	type LucideIcon,
	TextCursorInput,
	Trash2,
} from "lucide-react";
import { useState } from "react";
import { Link, useNavigate, useParams } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { formatDate } from "@/lib/format-date";
import { intlLocale } from "@/lib/intl-locale";
import {
	type AttachmentSummary,
	useAttachmentBacklinks,
	useBatchDeleteAttachments,
	useBatchMoveAttachments,
	useFolders,
	useRenameAttachment,
} from "../api/queries";
import { noteName } from "../lib/note-name";
import { noteHref, vaultRootHref } from "../routes";
import { formatBytes, type PreviewKind } from "./attachment-preview";
import { DeleteConfirm } from "./tree-actions/delete-confirm";
import { MoveDialog } from "./tree-actions/move-dialog";
import { RenameInput } from "./tree-actions/rename-input";

const ARCHIVE = /\.(?:zip|7z|rar|tar|gz|tgz|bz2|xz|zst)$/iu;

const KIND_ICONS: Record<PreviewKind, LucideIcon> = {
	image: FileImage,
	pdf: FileText,
	audio: FileAudio,
	video: FileVideo,
	csv: FileSpreadsheet,
	text: FileCode,
};

interface Props {
	att: AttachmentSummary;
	kind: PreviewKind | null;
	/** Set once the bytes are in memory; Open in new tab needs it. */
	inlineUrl: string | null;
	onDownload: () => void;
}

// The file card under (or, for files with no preview, instead of) the preview:
// what the file is, the actions on it, and the notes that point at it.
export function AttachmentDetails({ att, kind, inlineUrl, onDownload }: Props) {
	const { t, renderedLocale } = useT();
	const { slug } = useParams();
	const navigate = useNavigate();
	const { data: folders } = useFolders();
	const { data: backlinks } = useAttachmentBacklinks(att.id);
	const rename = useRenameAttachment();
	const move = useBatchMoveAttachments();
	const remove = useBatchDeleteAttachments();
	const [mode, setMode] = useState<"rename" | "move" | "delete" | null>(null);

	const filename = att.path.split("/").pop() ?? att.path;
	const folder = att.path.includes("/") ? att.path.slice(0, att.path.lastIndexOf("/")) : "";
	const Icon = ARCHIVE.test(filename) ? FileArchive : kind ? KIND_ICONS[kind] : File;
	const fmtLocale = intlLocale(renderedLocale);

	return (
		<section aria-label={t("File details")} className="flex flex-col gap-4 rounded-lg border p-4">
			<header className="flex items-center gap-3">
				<Icon className="size-10 shrink-0 text-muted-foreground" aria-hidden="true" />
				{mode === "rename" ? (
					<RenameInput
						initial={filename}
						kind="file"
						commitOnBlur
						onCommit={(next) => {
							setMode(null);
							const name = next.trim();
							if (name && name !== filename) {
								rename.mutate({
									old_path: att.path,
									new_path: folder ? `${folder}/${name}` : name,
								});
							}
						}}
						onCancel={() => setMode(null)}
					/>
				) : (
					<h2 className="min-w-0 break-all font-semibold text-lg" translate="no">
						{filename}
					</h2>
				)}
			</header>

			<dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
				<dt className="text-muted-foreground">{t("Size")}</dt>
				<dd>{formatBytes(att.size_bytes, fmtLocale)}</dd>
				<dt className="text-muted-foreground">{t("Type")}</dt>
				<dd translate="no">{att.mime_type || t("Unknown")}</dd>
				<dt className="text-muted-foreground">{t("Modified")}</dt>
				<dd>{formatDate(att.updated_at, fmtLocale)}</dd>
				<dt className="text-muted-foreground">{t("Folder")}</dt>
				<dd translate="no">{folder || t("Vault root")}</dd>
			</dl>

			<menu className="flex flex-wrap gap-2">
				<li>
					<Button onClick={onDownload}>
						<Download data-icon="inline-start" aria-hidden="true" />
						{t("Download")}
					</Button>
				</li>
				{inlineUrl ? (
					<li>
						<Button variant="outline" asChild>
							<a href={inlineUrl} target="_blank" rel="noopener noreferrer">
								<ExternalLink data-icon="inline-start" aria-hidden="true" />
								{t("Open in new tab")}
							</a>
						</Button>
					</li>
				) : null}
				<li>
					<Button variant="outline" onClick={() => setMode("rename")}>
						<TextCursorInput data-icon="inline-start" aria-hidden="true" />
						{t("Rename")}
					</Button>
				</li>
				<li>
					<Button variant="outline" onClick={() => setMode("move")}>
						<FolderInput data-icon="inline-start" aria-hidden="true" />
						{t("Move to…")}
					</Button>
				</li>
				<li>
					<Button variant="outline" onClick={() => setMode("delete")}>
						<Trash2 data-icon="inline-start" aria-hidden="true" />
						{t("Delete")}
					</Button>
				</li>
			</menu>

			<nav aria-label={t("Linked from")} className="text-sm">
				<h3 className="mb-1 font-medium text-muted-foreground">{t("Linked from")}</h3>
				{backlinks === undefined ? null : backlinks.length === 0 ? (
					<p className="text-muted-foreground">{t("No notes link to this file yet.")}</p>
				) : (
					<ul>
						{backlinks.map((b) => (
							<li key={b.source_note_id}>
								<Link
									to={noteHref(slug, b.source_note_id)}
									className="hover:underline"
									translate="no"
								>
									{b.source_title ?? noteName(b.source_path)}
								</Link>
							</li>
						))}
					</ul>
				)}
			</nav>

			{mode === "move" ? (
				<MoveDialog
					folders={folders ?? []}
					nodes={[{ kind: "file", path: att.path }]}
					onPick={(target) => {
						setMode(null);
						move.mutate({ paths: [att.path], target_folder: target });
					}}
					onCancel={() => setMode(null)}
				/>
			) : null}
			{mode === "delete" ? (
				<DeleteConfirm
					nodes={[{ kind: "file", path: att.path }]}
					onConfirm={() => {
						setMode(null);
						remove.mutate({ paths: [att.path] });
						navigate(vaultRootHref(slug));
					}}
					onCancel={() => setMode(null)}
				/>
			) : null}
		</section>
	);
}

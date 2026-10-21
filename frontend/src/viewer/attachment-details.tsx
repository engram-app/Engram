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
import { useNavigate, useParams } from "react-router";
import { Button } from "@/components/ui/button";
import { useT } from "@/i18n/locale-provider";
import { formatDate } from "@/lib/format-date";
import { intlLocale } from "@/lib/intl-locale";
import {
	type AttachmentSummary,
	useBatchDeleteAttachments,
	useBatchMoveAttachments,
	useFolders,
	useRenameAttachment,
} from "../api/queries";
import { vaultRootHref } from "../routes";
import {
	attachmentRenamePath,
	fileStem,
	formatBytes,
	type PreviewKind,
} from "./attachment-preview";
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

// File details under (or, for files with no preview, instead of) the preview:
// what the file is and the actions on it. Notes linking here are in the right
// rail's Backlinks panel, as for a note.
export function AttachmentDetails({ att, kind, inlineUrl, onDownload }: Props) {
	const { t, renderedLocale } = useT();
	const { slug } = useParams();
	const navigate = useNavigate();
	const { data: folders } = useFolders();
	const rename = useRenameAttachment();
	const move = useBatchMoveAttachments();
	const remove = useBatchDeleteAttachments();
	const [mode, setMode] = useState<"rename" | "move" | "delete" | null>(null);

	const filename = att.path.split("/").pop() ?? att.path;
	const { stem, ext } = fileStem(att.path);
	const folder = att.path.includes("/") ? att.path.slice(0, att.path.lastIndexOf("/")) : "";
	const Icon = ARCHIVE.test(filename) ? FileArchive : kind ? KIND_ICONS[kind] : File;
	const fmtLocale = intlLocale(renderedLocale);

	return (
		<section aria-label={t("File details")} className="flex flex-col gap-4">
			<header className="flex items-center gap-3">
				<Icon className="size-10 shrink-0 text-muted-foreground" aria-hidden="true" />
				{mode === "rename" ? (
					// Only the name is editable; the extension stays, so a rename never
					// changes what kind of file this is.
					<span className="flex min-w-0 items-baseline gap-0.5">
						<RenameInput
							initial={stem}
							kind="file"
							commitOnBlur
							onCommit={(next) => {
								setMode(null);
								const newPath = attachmentRenamePath(att.path, next);
								if (newPath) {
									rename.mutate({ old_path: att.path, new_path: newPath });
								}
							}}
							onCancel={() => setMode(null)}
						/>
						<span className="text-muted-foreground" translate="no">
							{ext}
						</span>
					</span>
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
					<Button variant="destructive" onClick={() => setMode("delete")}>
						<Trash2 data-icon="inline-start" aria-hidden="true" />
						{t("Delete")}
					</Button>
				</li>
			</menu>

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
